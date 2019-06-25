/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.9;
pragma experimental ABIEncoderV2;

import "@0x/contracts-utils/contracts/src/LibBytes.sol";
import "@0x/contracts-utils/contracts/src/LibEIP1271.sol";
import "@0x/contracts-utils/contracts/src/ReentrancyGuard.sol";
import "@0x/contracts-utils/contracts/src/RichErrors.sol";
import "@0x/contracts-exchange-libs/contracts/src/LibOrder.sol";
import "./interfaces/IWallet.sol";
import "./interfaces/IEIP1271Wallet.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/IOrderValidator.sol";
import "./interfaces/ISignatureValidator.sol";
import "./MixinTransactions.sol";
import "./MixinExchangeRichErrors.sol";


contract MixinSignatureValidator is
    MixinExchangeRichErrors,
    ReentrancyGuard,
    LibOrder,
    LibEIP1271,
    ISignatureValidator,
    MixinTransactions
{
    using LibBytes for bytes;

    // Mapping of hash => signer => signed
    mapping (bytes32 => mapping (address => bool)) public preSigned;

    // Mapping of signer => validator => approved
    mapping (address => mapping (address => bool)) public allowedValidators;

    // Mapping of signer => order validator => approved
    mapping (address => mapping (address => bool)) public allowedOrderValidators;

    /// @dev Approves a hash on-chain.
    ///      After presigning a hash, the preSign signature type will become valid for that hash and signer.
    /// @param hash Any 32-byte hash.
    function preSign(bytes32 hash)
        external
        nonReentrant
    {
        address signerAddress = _getCurrentContextAddress();
        preSigned[hash][signerAddress] = true;
    }

    /// @dev Approves/unnapproves a Validator contract to verify signatures on signer's behalf
    ///      using the `Validator` signature type.
    /// @param validatorAddress Address of Validator contract.
    /// @param approval Approval or disapproval of  Validator contract.
    function setSignatureValidatorApproval(
        address validatorAddress,
        bool approval
    )
        external
        nonReentrant
    {
        address signerAddress = _getCurrentContextAddress();
        allowedValidators[signerAddress][validatorAddress] = approval;
        emit SignatureValidatorApproval(
            signerAddress,
            validatorAddress,
            approval
        );
    }

    /// @dev Approves/unnapproves an OrderValidator contract to verify signatures on signer's behalf
    ///      using the `OrderValidator` signature type.
    /// @param validatorAddress Address of Validator contract.
    /// @param approval Approval or disapproval of  Validator contract.
    function setOrderValidatorApproval(
        address validatorAddress,
        bool approval
    )
        external
        nonReentrant
    {
        address signerAddress = _getCurrentContextAddress();
        allowedOrderValidators[signerAddress][validatorAddress] = approval;
        emit SignatureValidatorApproval(
            signerAddress,
            validatorAddress,
            approval
        );
    }

    /// @dev Verifies that a signature for an order is valid.
    /// @param order The order.
    /// @param signerAddress Address that should have signed the given order.
    /// @param signature Proof that the order has been signed by signer.
    /// @return True if the signature is valid for the given order and signer.
    function isValidOrderSignature(
        Order memory order,
        address signerAddress,
        bytes memory signature
    )
        public
        view
        returns (bool isValid)
    {
        bytes32 orderHash = getOrderHash(order);
        return _isValidOrderWithHashSignature(
            order,
            orderHash,
            signerAddress,
            signature
        );
    }

    /// @dev Verifies that a hash has been signed by the given signer.
    /// @param hash Any 32-byte hash.
    /// @param signerAddress Address that should have signed the given hash.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if the signature is valid for the given hash and signer.
    function isValidHashSignature(
        bytes32 hash,
        address signerAddress,
        bytes memory signature
    )
        public
        view
        returns (bool isValid)
    {
        SignatureType signatureType = _readValidSignatureType(
            hash,
            signerAddress,
            signature
        );
        // Only hash-compatible signature types can be handled by this
        // function.
        if (
            signatureType == SignatureType.OrderValidator ||
            signatureType == SignatureType.OrderWallet ||
            signatureType == SignatureType.EIP1271OrderWallet
        ) {
            _rrevert(SignatureError(
                SignatureErrorCodes.INAPPROPRIATE_SIGNATURE_TYPE,
                hash,
                signerAddress,
                signature
            ));
        }
        return _validateHashSignatureTypes(
            signatureType,
            hash,
            signerAddress,
            signature
        );
    }

    /// @dev Checks if a signature is of a type that should be verified for
    /// every subsequent fill.
    /// @param orderHash The hash of the order.
    /// @param signerAddress The address of the signer.
    /// @param signature The signature for `orderHash`.
    /// @return needsRegularValidation True if the signature should be validated
    ///                                for every operation.
    function doesSignatureRequireRegularValidation(
        bytes32 orderHash,
        address signerAddress,
        bytes memory signature
    )
        public
        pure
        returns (bool needsRegularValidation)
    {
        SignatureType signatureType =  _readValidSignatureType(
            orderHash,
            signerAddress,
            signature
        );
        // Only signature types that take a full order should be validated
        // regularly.
        return
            signatureType == SignatureType.OrderValidator ||
            signatureType == SignatureType.OrderWallet ||
            signatureType == SignatureType.EIP1271OrderWallet;
    }

    /// @dev Verifies that an order, with provided order hash, has been signed
    ///      by the given signer.
    /// @param order The order.
    /// @param orderHash The hash of the order.
    /// @param signerAddress Address that should have signed the.Signat given hash.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return isValid True if the signature is valid for the given hash and signer.
    function _isValidOrderWithHashSignature(
        Order memory order,
        bytes32 orderHash,
        address signerAddress,
        bytes memory signature
    )
        internal
        view
        returns (bool isValid)
    {
        SignatureType signatureType = _readValidSignatureType(
            orderHash,
            signerAddress,
            signature
        );
        if (signatureType == SignatureType.OrderValidator) {
            // The entire order is verified by validator contract.
            isValid = _validateOrderWithValidator(
                order,
                orderHash,
                signerAddress,
                signature
            );
            return isValid;
        } else if (signatureType == SignatureType.OrderWallet) {
            // The entire order is verified by a wallet contract.
            isValid = _validateOrderWithWallet(
                order,
                orderHash,
                signerAddress,
                signature
            );
            return isValid;
        } else if (signatureType == SignatureType.EIP1271OrderWallet) {
            // The entire order is verified by a wallet contract.
            isValid = _validateOrderWithEIP1271Wallet(
                order,
                orderHash,
                signerAddress,
                signature
            );
            return isValid;
        }
        // Otherwise, it's one of the hash-compatible signature types.
        return _validateHashSignatureTypes(
            signatureType,
            orderHash,
            signerAddress,
            signature
        );
    }

    /// Reads the `SignatureType` from the end of a signature and validates it.
    function _readValidSignatureType(
        bytes32 hash,
        address signerAddress,
        bytes memory signature
    )
        private
        pure
        returns (SignatureType signatureType)
    {
        if (signature.length == 0) {
            _rrevert(SignatureError(
                SignatureErrorCodes.INVALID_LENGTH,
                hash,
                signerAddress,
                signature
            ));
        }

        // Read the last byte off of signature byte array.
        uint8 signatureTypeRaw = uint8(signature[signature.length - 1]);

        // Ensure signature is supported
        if (signatureTypeRaw >= uint8(SignatureType.NSignatureTypes)) {
            _rrevert(SignatureError(
                SignatureErrorCodes.UNSUPPORTED,
                hash,
                signerAddress,
                signature
            ));
        }

        // Always illegal signature.
        // This is always an implicit option since a signer can create a
        // signature array with invalid type or length. We may as well make
        // it an explicit option. This aids testing and analysis. It is
        // also the initialization value for the enum type.
        if (SignatureType(signatureTypeRaw) == SignatureType.Illegal) {
            _rrevert(SignatureError(
                SignatureErrorCodes.ILLEGAL,
                hash,
                signerAddress,
                signature
            ));
        }

        return SignatureType(signatureTypeRaw);
    }

    /// @dev Verifies signature using logic defined by Wallet contract.
    /// @param hash Any 32 byte hash.
    /// @param walletAddress Address that should have signed the given hash
    ///                      and defines its own signature verification method.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if the signature is validated by the Walidator.
    function _validateHashWithWallet(
        bytes32 hash,
        address walletAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        uint256 signatureLength = signature.length;
        // Shave the signature type off the signature.
        assembly {
            mstore(signature, sub(signatureLength, 1))
        }
        // Encode the call data.
        bytes memory callData = abi.encodeWithSelector(
            IWallet(walletAddress).isValidSignature.selector,
            hash,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = walletAddress.staticcall(callData);
        // Return data should be a single bool.
        if (didSucceed && returnData.length == 32) {
            return returnData.readUint256(0) == 1;
        }
        // Static call to verifier failed.
        _rrevert(SignatureWalletError(
            hash,
            walletAddress,
            signature,
            returnData
        ));
    }

    /// @dev Verifies signature using logic defined by an EIP1271 Wallet contract.
    /// @param hash Any 32 byte hash.
    /// @param walletAddress Address that should have signed the given hash
    ///                      and defines its own signature verification method.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if the signature is validated by the Walidator.
    function _validateHashWithEIP1271Wallet(
        bytes32 hash,
        address walletAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        uint256 signatureLength = signature.length;
        // Shave the signature type off the signature.
        assembly {
            mstore(signature, sub(signatureLength, 1))
        }
        // Encode the call data.
        bytes memory data = new bytes(32);
        data.writeBytes32(0, hash);
        bytes memory callData = abi.encodeWithSelector(
            IEIP1271Wallet(walletAddress).isValidSignature.selector,
            data,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = walletAddress.staticcall(callData);
        // Return data should be the `EIP1271_MAGIC_VALUE`.
        if (didSucceed && returnData.length <= 32) {
            return returnData.readBytes4(0) == EIP1271_MAGIC_VALUE;
        }
        // Static call to verifier failed.
        _rrevert(SignatureWalletError(
            hash,
            walletAddress,
            signature,
            returnData
        ));
    }

    /// @dev Verifies signature using logic defined by Validator contract.
    ///      If used with an order, the maker of the order can still be an EOA.
    /// @param hash Any 32 byte hash.
    /// @param signerAddress Address that should have signed the given hash.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if the signature is validated by the Validator.
    function _validateHashWithValidator(
        bytes32 hash,
        address signerAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        // If used with an order, the maker of the order can still be an EOA.
        // A signature using this type should be encoded as:
        // | Offset   | Length | Contents                        |
        // | 0x00     | x      | Signature to validate           |
        // | 0x00 + x | 20     | Address of validator contract   |
        // | 0x14 + x | 1      | Signature type is always "\x06" |

        uint256 signatureLength = signature.length;
        // Read the validator address from the signature.
        address validatorAddress = signature.readAddress(signatureLength - 21);
        // Ensure signer has approved validator.
        if (!allowedValidators[signerAddress][validatorAddress]) {
            _rrevert(SignatureValidatorNotApprovedError(
                signerAddress,
                validatorAddress
            ));
        }
        // Shave the validator address and signature type from the signature.
        assembly {
            mstore(signature, sub(signatureLength, 21))
        }
        // Encode the call data.
        bytes memory callData = abi.encodeWithSelector(
            IValidator(validatorAddress).isValidSignature.selector,
            hash,
            signerAddress,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = validatorAddress.staticcall(callData);
        // Return data should be a single bool.
        if (didSucceed && returnData.length == 32) {
            return returnData.readUint256(0) == 1;
        }
        // Static call to verifier failed.
        _rrevert(SignatureValidatorError(
            hash,
            signerAddress,
            validatorAddress,
            signature,
            returnData
        ));
    }

    /// @dev Verifies order AND signature via a Wallet contract.
    /// @param order The order.
    /// @param orderHash The order hash.
    /// @param walletAddress Address that should have signed the given hash
    ///                      and defines its own order/signature verification method.
    /// @param signature Proof that the order has been signed by signer.
    /// @return True if order and signature are validated by the Wallet.
    function _validateOrderWithWallet(
        Order memory order,
        bytes32 orderHash,
        address walletAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        uint256 signatureLength = signature.length;
        // Shave the signature type off the signature.
        assembly {
            mstore(signature, sub(signatureLength, 1))
        }
        // Encode the call data.
        bytes memory callData = abi.encodeWithSelector(
            IWallet(walletAddress).isValidOrderSignature.selector,
            order,
            orderHash,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = walletAddress.staticcall(callData);
        // Return data should be a single bool.
        if (didSucceed && returnData.length == 32) {
            return returnData.readUint256(0) == 1;
        }
        // Static call to verifier failed.
        _rrevert(SignatureOrderWalletError(
            orderHash,
            walletAddress,
            signature,
            returnData
        ));
    }

    /// @dev Verifies order AND signature via an EIP1271 Wallet contract.
    /// @param order The order.
    /// @param orderHash The order hash.
    /// @param walletAddress Address that should have signed the given hash
    ///                      and defines its own order/signature verification method.
    /// @param signature Proof that the order has been signed by signer.
    /// @return True if order and signature are validated by the Wallet.
    function _validateOrderWithEIP1271Wallet(
        Order memory order,
        bytes32 orderHash,
        address walletAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        uint256 signatureLength = signature.length;
        // Shave the signature type off the signature.
        assembly {
            mstore(signature, sub(signatureLength, 1))
        }
        // Encode the call data.
        bytes memory data = abi.encode(order);
        bytes memory callData = abi.encodeWithSelector(
            IEIP1271Wallet(walletAddress).isValidSignature.selector,
            data,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = walletAddress.staticcall(callData);
        // Return data should be the `EIP1271_MAGIC_VALUE`.
        if (didSucceed && returnData.length <= 32) {
            return returnData.readBytes4(0) == EIP1271_MAGIC_VALUE;
        }
        // Static call to verifier failed.
        _rrevert(SignatureOrderWalletError(
            orderHash,
            walletAddress,
            signature,
            returnData
        ));
    }

    /// @dev Verifies order AND signature via Validator contract.
    ///      If used with an order, the maker of the order can still be an EOA.
    /// @param order The order.
    /// @param orderHash The order hash.
    /// @param signerAddress Address that should have signed the given hash.
    /// @param signature Proof that the hash has been signed by signer.
    /// @return True if order and signature are validated by the Validator.
    function _validateOrderWithValidator(
        Order memory order,
        bytes32 orderHash,
        address signerAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        // A signature using this type should be encoded as:
        // | Offset   | Length | Contents                        |
        // | 0x00     | x      | Signature to validate           |
        // | 0x00 + x | 20     | Address of validator contract   |
        // | 0x14 + x | 1      | Signature type is always "\x07" |

        uint256 signatureLength = signature.length;
        // Read the validator address from the signature.
        address validatorAddress = signature.readAddress(signatureLength - 21);
        // Ensure signer has approved validator.
        if (!allowedOrderValidators[signerAddress][validatorAddress]) {
            _rrevert(SignatureOrderValidatorNotApprovedError(
                signerAddress,
                validatorAddress
            ));
        }
        // Shave the validator address and signature type from the signature.
        assembly {
            mstore(signature, sub(signatureLength, 21))
        }
        // Encode the call data.
        bytes memory callData = abi.encodeWithSelector(
            IOrderValidator(validatorAddress).isValidOrderSignature.selector,
            order,
            orderHash,
            signature
        );
        // Restore the full signature.
        assembly {
            mstore(signature, signatureLength)
        }
        // Static call the verification function.
        (bool didSucceed, bytes memory returnData) = validatorAddress.staticcall(callData);
        // Return data should be a single bool.
        if (didSucceed && returnData.length == 32) {
            return returnData.readUint256(0) == 1;
        }
        // Static call to verifier failed.
        _rrevert(SignatureOrderValidatorError(
            orderHash,
            signerAddress,
            validatorAddress,
            signature,
            returnData
        ));
    }

    /// Validates a hash-compatible signature type
    /// (anything but `OrderValidator` and `OrderWallet`).
    function _validateHashSignatureTypes(
        SignatureType signatureType,
        bytes32 hash,
        address signerAddress,
        bytes memory signature
    )
        private
        view
        returns (bool isValid)
    {
        // Always invalid signature.
        // Like Illegal, this is always implicitly available and therefore
        // offered explicitly. It can be implicitly created by providing
        // a correctly formatted but incorrect signature.
        if (signatureType == SignatureType.Invalid) {
            if (signature.length != 1) {
                _rrevert(SignatureError(
                    SignatureErrorCodes.INVALID_LENGTH,
                    hash,
                    signerAddress,
                    signature
                ));
            }
            isValid = false;
            return isValid;

        // Signature using EIP712
        } else if (signatureType == SignatureType.EIP712) {
            if (signature.length != 66) {
                _rrevert(SignatureError(
                    SignatureErrorCodes.INVALID_LENGTH,
                    hash,
                    signerAddress,
                    signature
                ));
            }
            uint8 v = uint8(signature[0]);
            bytes32 r = signature.readBytes32(1);
            bytes32 s = signature.readBytes32(33);
            address recovered = ecrecover(
                hash,
                v,
                r,
                s
            );
            isValid = signerAddress == recovered;
            return isValid;

        // Signed using web3.eth_sign
        } else if (signatureType == SignatureType.EthSign) {
            if (signature.length != 66) {
                _rrevert(SignatureError(
                    SignatureErrorCodes.INVALID_LENGTH,
                    hash,
                    signerAddress,
                    signature
                ));
            }
            uint8 v = uint8(signature[0]);
            bytes32 r = signature.readBytes32(1);
            bytes32 s = signature.readBytes32(33);
            address recovered = ecrecover(
                keccak256(abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    hash
                )),
                v,
                r,
                s
            );
            isValid = signerAddress == recovered;
            return isValid;

        // Signature verified by wallet contract.
        // If used with an order, the maker of the order is the wallet contract.
        } else if (signatureType == SignatureType.Wallet) {
            isValid = _validateHashWithWallet(
                hash,
                signerAddress,
                signature
            );
            return isValid;

        // Signature verified by validator contract.
        // If used with an order, the maker of the order can still be an EOA.
        } else if (signatureType == SignatureType.Validator) {
            isValid = _validateHashWithValidator(
                hash,
                signerAddress,
                signature
            );
            return isValid;

        // Signature verified by an EIP1271 wallet contract.
        // If used with an order, the maker of the order is the wallet contract.
        } else if (signatureType == SignatureType.EIP1271Wallet) {
            isValid = _validateHashWithEIP1271Wallet(
                hash,
                signerAddress,
                signature
            );
            return isValid;
        }
        // Otherwise, signatureType == SignatureType.PreSigned
        assert(signatureType == SignatureType.PreSigned);
        // Signer signed hash previously using the preSign function.
        return preSigned[hash][signerAddress];
    }
}
