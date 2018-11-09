import { BigNumber } from '@0x/utils';
import * as _ from 'lodash';
import * as React from 'react';

import { ColorOption } from '../style/theme';
import { Account, AccountState, Network, StandardSlidingPanelContent } from '../types';

import { MetaMaskLogo } from './meta_mask_logo';
import { PaymentMethodDropdown } from './payment_method_dropdown';
import { Circle } from './ui/circle';
import { Container } from './ui/container';
import { Flex } from './ui/flex';
import { Text } from './ui/text';

export interface PaymentMethodProps {
    account: Account;
    network: Network;
    openStandardSlidingPanel: (content: StandardSlidingPanelContent) => void;
}

export class PaymentMethod extends React.Component<PaymentMethodProps> {
    public render(): React.ReactNode {
        return (
            <Container padding="20px" width="100%">
                <Container marginBottom="12px">
                    <Flex justify="space-between">
                        <Text
                            letterSpacing="1px"
                            fontColor={ColorOption.primaryColor}
                            fontWeight={600}
                            textTransform="uppercase"
                            fontSize="14px"
                        >
                            {this._renderTitleText()}
                        </Text>
                        <Flex>{this._renderTitleLabel()}</Flex>
                    </Flex>
                </Container>
                {this._renderMainContent()}
            </Container>
        );
    }
    private readonly _renderTitleText = (): string => {
        const { account } = this.props;
        switch (account.state) {
            case AccountState.Loading:
                return 'loading...';
            case AccountState.Error:
            case AccountState.Locked:
            case AccountState.None:
                return 'connect your wallet';
            case AccountState.Ready:
                return 'payment method';
            default:
                return 'payment method';
        }
    };
    private readonly _renderTitleLabel = (): React.ReactNode => {
        const { account } = this.props;
        if (account.state === AccountState.Ready) {
            return (
                <React.Fragment>
                    <Circle color={ColorOption.green} diameter={8} />
                    <Container marginLeft="3px">
                        <Text fontColor={ColorOption.darkGrey} fontSize="12px">
                            MetaMask
                        </Text>
                    </Container>
                </React.Fragment>
            );
        }
        return null;
    };
    private readonly _renderMainContent = (): React.ReactNode => {
        const { account, network } = this.props;
        switch (account.state) {
            case AccountState.Loading:
                return 'loading...';
            case AccountState.Locked:
                return <WalletPrompt onClick={this._openInstallWalletPanel}>Unlock MetaMask</WalletPrompt>;
            case AccountState.None:
                return <WalletPrompt onClick={this._openInstallWalletPanel}>Install MetaMask</WalletPrompt>;
            case AccountState.Ready:
                return (
                    <PaymentMethodDropdown
                        accountAddress={account.address}
                        accountEthBalanceInWei={account.ethBalanceInWei}
                        network={network}
                    />
                );
            default:
                return 'payment method';
        }
    };
    private readonly _openInstallWalletPanel = () => {
        this.props.openStandardSlidingPanel(StandardSlidingPanelContent.InstallWallet);
    };
}

interface WalletPromptProps {
    onClick?: () => void;
}

const WalletPrompt: React.StatelessComponent<WalletPromptProps> = ({ onClick, children }) => (
    <Container
        padding="12px"
        border={`1px solid ${ColorOption.darkOrange}`}
        backgroundColor={ColorOption.lightOrange}
        width="100%"
        borderRadius="4px"
        onClick={onClick}
        cursor={onClick ? 'pointer' : undefined}
        boxShadowOnHover={!!onClick}
    >
        <Flex>
            <Container marginRight="10px">
                <MetaMaskLogo width={19} height={18} />
            </Container>
            <Text fontSize="16px" fontColor={ColorOption.darkOrange}>
                {children}
            </Text>
        </Flex>
    </Container>
);
