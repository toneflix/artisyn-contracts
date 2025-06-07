#[starknet::component]
pub mod FeeManagerComponent {
    use artisyn::interfaces::IFeeManager::{FeeConfig, FeeHistory, IFeeManager};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::access::ownable::OwnableComponent::{InternalImpl, OwnableMixinImpl};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    #[storage]
    pub struct Storage {
        // Fee configuration
        fee_config: FeeConfig,
        // Fee collection state
        fee_collection_paused: bool,
        transaction_counter: u256,
        // Stakeholder management
        stakeholders: Map<ContractAddress, u256>, // stakeholder -> share_bps
        stakeholder_list: Map<u256, ContractAddress>, // index -> stakeholder
        stakeholder_count: u256,
        total_stakeholder_shares: u256,
        // Fee history and tracking
        fee_history: Map<u256, FeeHistory>, // transaction_id -> history
        fee_history_count: u256,
        // Fee totals per token
        total_platform_fees: Map<ContractAddress, u256>, // token -> total_fees
        total_artisan_fees: Map<ContractAddress, u256>, // token -> total_fees
        // User tracking per token
        user_fees_paid: Map<(ContractAddress, ContractAddress), u256>, // (user, token) -> fees_paid
        artisan_fees_earned: Map<
            (ContractAddress, ContractAddress), u256,
        >, // (artisan, token) -> fees_earned
        // Collected balances per token
        collected_balances: Map<ContractAddress, u256>, // token -> balance
        // Supported tokens
        supported_tokens: Map<ContractAddress, bool>,
        supported_token_list: Map<u256, ContractAddress>,
        supported_token_count: u256,
        default_token: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        FeeConfigUpdated: FeeConfigUpdated,
        FeeCollected: FeeCollected,
        FeesDistributed: FeesDistributed,
        StakeholderAdded: StakeholderAdded,
        StakeholderRemoved: StakeholderRemoved,
        StakeholderShareUpdated: StakeholderShareUpdated,
        FeeCollectionPaused: FeeCollectionPaused,
        FeeCollectionUnpaused: FeeCollectionUnpaused,
        EmergencyWithdrawal: EmergencyWithdrawal,
        PlatformFeeUpdated: PlatformFeeUpdated,
        ArtisanFeeUpdated: ArtisanFeeUpdated,
        TreasuryAddressUpdated: TreasuryAddressUpdated,
        TokenAdded: TokenAdded,
        TokenRemoved: TokenRemoved,
        TokenTransfer: TokenTransfer,
        FeesDistributedInToken: FeesDistributedInToken,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeConfigUpdated {
        pub platform_fee_bps: u256,
        pub artisan_fee_bps: u256,
        pub max_fee_bps: u256,
        pub default_token: ContractAddress,
        pub min_transaction_amount: u256,
        pub treasury_address: ContractAddress,
        pub is_active: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeesDistributed {
        pub total_amount: u256,
        pub stakeholder_count: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeholderAdded {
        pub stakeholder: ContractAddress,
        pub share_bps: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeholderRemoved {
        pub stakeholder: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakeholderShareUpdated {
        pub stakeholder: ContractAddress,
        pub old_share_bps: u256,
        pub new_share_bps: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeCollectionPaused {
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeCollectionUnpaused {
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct EmergencyWithdrawal {
        pub token: ContractAddress,
        pub amount: u256,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PlatformFeeUpdated {
        pub old_fee_bps: u256,
        pub new_fee_bps: u256,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ArtisanFeeUpdated {
        pub old_fee_bps: u256,
        pub new_fee_bps: u256,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TreasuryAddressUpdated {
        pub old_treasury: ContractAddress,
        pub new_treasury: ContractAddress,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenAdded {
        pub token: ContractAddress,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenRemoved {
        pub token: ContractAddress,
        pub by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TokenTransfer {
        pub token: ContractAddress,
        pub from: ContractAddress,
        pub to: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeeCollected {
        pub transaction_id: u256,
        pub token: ContractAddress,
        pub payer: ContractAddress,
        pub amount: u256,
        pub platform_fee: u256,
        pub artisan_fee: u256,
        pub artisan: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FeesDistributedInToken {
        pub token: ContractAddress,
        pub total_amount: u256,
        pub stakeholder_count: u256,
    }

    // === Component Errors ===
    pub mod Errors {
        pub const NOT_OWNER: felt252 = 'Caller is not the owner';
        pub const FEE_COLLECTION_PAUSED: felt252 = 'Fee collection is paused';
        pub const INVALID_FEE_AMOUNT: felt252 = 'Invalid fee amount';
        pub const INVALID_STAKEHOLDER: felt252 = 'Invalid stakeholder address';
        pub const STAKEHOLDER_EXISTS: felt252 = 'Stakeholder already exists';
        pub const STAKEHOLDER_NOT_FOUND: felt252 = 'Stakeholder not found';
        pub const INVALID_SHARE: felt252 = 'Invalid share percentage';
        pub const TOTAL_SHARES_EXCEED_100: felt252 = 'Total shares exceed 100%';
        pub const AMOUNT_TOO_SMALL: felt252 = 'Amount below minimum';
        pub const INVALID_TREASURY: felt252 = 'Invalid treasury address';
        pub const ZERO_AMOUNT: felt252 = 'Amount cannot be zero';
        pub const INVALID_INDEX: felt252 = 'Invalid history index';
        pub const INSUFFICIENT_BALANCE: felt252 = 'Insufficient balance';
        pub const TOKEN_NOT_SUPPORTED: felt252 = 'Token not supported';
        pub const TOKEN_ALREADY_SUPPORTED: felt252 = 'Token already supported';
        pub const TRANSFER_FAILED: felt252 = 'Token transfer failed';
        pub const INVALID_TOKEN: felt252 = 'Invalid token address';
    }

    // === Internal Implementation ===
    #[generate_trait]
    pub impl Private<
        TContractState,
        +Drop<TContractState>,
        +HasComponent<TContractState>,
        impl Ownable: OwnableComponent::HasComponent<TContractState>,
    > of PrivateTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>, initial_config: FeeConfig) {
            self._validate_fee_config(@initial_config);
            self.default_token.write(initial_config.default_token);
            self._add_supported_token(initial_config.default_token);
            self.fee_config.write(initial_config);
            self.fee_collection_paused.write(false);
            self.transaction_counter.write(0);
            self.stakeholder_count.write(0);
            self.total_stakeholder_shares.write(0);
            self.fee_history_count.write(0);
            self.supported_token_count.write(1);
        }

        fn _assert_only_owner(self: @ComponentState<TContractState>, caller: ContractAddress) {
            let ownable_component = get_dep_component!(self, Ownable);
            let owner = ownable_component.owner();
            assert(caller == owner, 'Caller is not the owner');
        }

        fn _validate_fee_config(self: @ComponentState<TContractState>, config: @FeeConfig) {
            assert(
                *config.platform_fee_bps + *config.artisan_fee_bps <= *config.max_fee_bps,
                'Invalid fee amount',
            );
            assert(*config.max_fee_bps <= 10000, 'Invalid fee amount'); // Max 100%
        }

        fn _assert_not_paused(self: @ComponentState<TContractState>) {
            assert(!self.fee_collection_paused.read(), 'Fee collection is paused');
        }

        fn _assert_token_supported(self: @ComponentState<TContractState>, token: ContractAddress) {
            assert(self.supported_tokens.entry(token).read(), 'Token not supported');
        }

        fn _calculate_fee_amount(
            self: @ComponentState<TContractState>, amount: u256, fee_bps: u256,
        ) -> u256 {
            (amount * fee_bps) / 10000
        }

        fn _record_fee_history(
            ref self: ComponentState<TContractState>,
            payer: ContractAddress,
            amount: u256,
            platform_fee: u256,
            artisan_fee: u256,
        ) -> u256 {
            let transaction_id = self.transaction_counter.read() + 1;
            self.transaction_counter.write(transaction_id);

            let history = FeeHistory {
                transaction_id,
                payer,
                amount,
                platform_fee,
                artisan_fee,
                timestamp: get_block_timestamp(),
            };

            let history_index = self.fee_history_count.read();
            self.fee_history.entry(history_index).write(history);
            self.fee_history_count.write(history_index + 1);

            transaction_id
        }

        fn _update_fee_totals(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            platform_fee: u256,
            artisan_fee: u256,
            payer: ContractAddress,
            artisan: ContractAddress,
        ) {
            // Update total fees per token
            let current_platform_total = self.total_platform_fees.entry(token).read();
            self.total_platform_fees.entry(token).write(current_platform_total + platform_fee);

            let current_artisan_total = self.total_artisan_fees.entry(token).read();
            self.total_artisan_fees.entry(token).write(current_artisan_total + artisan_fee);

            // Update user tracking per token
            let current_user_fees = self.user_fees_paid.entry((payer, token)).read();
            self
                .user_fees_paid
                .entry((payer, token))
                .write(current_user_fees + platform_fee + artisan_fee);

            // Update artisan tracking per token
            let current_artisan_fees = self.artisan_fees_earned.entry((artisan, token)).read();
            self
                .artisan_fees_earned
                .entry((artisan, token))
                .write(current_artisan_fees + artisan_fee);
        }

        fn _transfer_token(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            from: ContractAddress,
            to: ContractAddress,
            amount: u256,
        ) -> bool {
            if amount == 0 {
                return true;
            }

            let token_dispatcher = IERC20Dispatcher { contract_address: token };

            if from == get_contract_address() {
                // Transfer from contract
                token_dispatcher.transfer(to, amount)
            } else {
                // Transfer from user to contract
                token_dispatcher.transfer_from(from, to, amount)
            }
        }

        fn _collect_fees_in_token(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            payer: ContractAddress,
            amount: u256,
            platform_fee: u256,
            artisan_fee: u256,
            artisan: ContractAddress,
        ) -> bool {
            let total_fee = platform_fee + artisan_fee;
            if total_fee == 0 {
                return true;
            }

            let contract_address = get_contract_address();

            // Transfer platform fee to contract
            if platform_fee > 0 {
                let success = self._transfer_token(token, payer, contract_address, platform_fee);
                if !success {
                    return false;
                }

                // Update collected balance
                let current_balance = self.collected_balances.entry(token).read();
                self.collected_balances.entry(token).write(current_balance + platform_fee);
            }

            // Transfer artisan fee directly to artisan
            if artisan_fee > 0 {
                let success = self._transfer_token(token, payer, artisan, artisan_fee);
                if !success {
                    return false;
                }
            }

            self
                .emit(
                    TokenTransfer {
                        token, from: payer, to: contract_address, amount: platform_fee,
                    },
                );

            if artisan_fee > 0 {
                self.emit(TokenTransfer { token, from: payer, to: artisan, amount: artisan_fee });
            }

            true
        }

        fn _add_supported_token(ref self: ComponentState<TContractState>, token: ContractAddress) {
            if !self.supported_tokens.entry(token).read() {
                self.supported_tokens.entry(token).write(true);

                let count = self.supported_token_count.read();
                self.supported_token_list.entry(count).write(token);
                self.supported_token_count.write(count + 1);
            }
        }
    }

    // === External Implementation ===
    #[embeddable_as(FeeManagerImpl)]
    impl FeeManager<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        impl Ownable: OwnableComponent::HasComponent<TContractState>,
    > of IFeeManager<ComponentState<TContractState>> {
        // === Fee Configuration ===
        fn set_fee_config(ref self: ComponentState<TContractState>, config: FeeConfig) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            self._validate_fee_config(@config);
            self.default_token.write(config.default_token);
            self._add_supported_token(config.default_token);
            self.fee_config.write(config.clone());

            self
                .emit(
                    FeeConfigUpdated {
                        platform_fee_bps: config.platform_fee_bps,
                        artisan_fee_bps: config.artisan_fee_bps,
                        max_fee_bps: config.max_fee_bps,
                        default_token: config.default_token,
                        min_transaction_amount: config.min_transaction_amount,
                        treasury_address: config.treasury_address,
                        is_active: config.is_active,
                    },
                );
        }

        fn get_fee_config(self: @ComponentState<TContractState>) -> FeeConfig {
            self.fee_config.read()
        }

        fn update_platform_fee(ref self: ComponentState<TContractState>, fee_bps: u256) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let mut config = self.fee_config.read();
            let old_fee = config.platform_fee_bps;

            assert(fee_bps + config.artisan_fee_bps <= config.max_fee_bps, 'Invalid fee amount');

            config.platform_fee_bps = fee_bps;
            self.fee_config.write(config);

            self
                .emit(
                    PlatformFeeUpdated {
                        old_fee_bps: old_fee, new_fee_bps: fee_bps, by: get_caller_address(),
                    },
                );
        }

        fn update_artisan_fee(ref self: ComponentState<TContractState>, fee_bps: u256) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let mut config = self.fee_config.read();
            let old_fee = config.artisan_fee_bps;

            assert(config.platform_fee_bps + fee_bps <= config.max_fee_bps, 'Invalid fee amount');

            config.artisan_fee_bps = fee_bps;
            self.fee_config.write(config);

            self
                .emit(
                    ArtisanFeeUpdated {
                        old_fee_bps: old_fee, new_fee_bps: fee_bps, by: get_caller_address(),
                    },
                );
        }

        fn update_treasury_address(
            ref self: ComponentState<TContractState>, treasury: ContractAddress,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let mut config = self.fee_config.read();
            let old_treasury = config.treasury_address;
            config.treasury_address = treasury;
            self.fee_config.write(config);

            self
                .emit(
                    TreasuryAddressUpdated {
                        old_treasury, new_treasury: treasury, by: get_caller_address(),
                    },
                );
        }

        fn set_fee_active(ref self: ComponentState<TContractState>, active: bool) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let mut config = self.fee_config.read();
            config.is_active = active;
            self.fee_config.write(config);

            if active {
                self.emit(FeeCollectionUnpaused { by: get_caller_address() });
            } else {
                self.emit(FeeCollectionPaused { by: get_caller_address() });
            }
        }

        // === Fee Calculation ===
        fn calculate_fees(self: @ComponentState<TContractState>, amount: u256) -> (u256, u256) {
            let config = self.fee_config.read();

            if !config.is_active || amount < config.min_transaction_amount {
                return (0, 0);
            }

            let platform_fee = self._calculate_fee_amount(amount, config.platform_fee_bps);
            let artisan_fee = self._calculate_fee_amount(amount, config.artisan_fee_bps);

            (platform_fee, artisan_fee)
        }

        fn calculate_total_fee(self: @ComponentState<TContractState>, amount: u256) -> u256 {
            let (platform_fee, artisan_fee) = self.calculate_fees(amount);
            platform_fee + artisan_fee
        }

        fn get_net_amount(self: @ComponentState<TContractState>, gross_amount: u256) -> u256 {
            let total_fee = self.calculate_total_fee(gross_amount);
            gross_amount - total_fee
        }

        // === Fee Collection ===
        fn collect_fees(
            ref self: ComponentState<TContractState>,
            payer: ContractAddress,
            amount: u256,
            artisan: ContractAddress,
        ) -> (u256, u256) {
            self.collect_fees_in_token(self.default_token.read(), payer, amount, artisan)
        }

        fn collect_fees_in_token(
            ref self: ComponentState<TContractState>,
            token: ContractAddress,
            payer: ContractAddress,
            amount: u256,
            artisan: ContractAddress,
        ) -> (u256, u256) {
            self._assert_not_paused();
            self._assert_token_supported(token);

            assert(amount > 0, 'Amount cannot be zero');

            let (platform_fee, artisan_fee) = self.calculate_fees(amount);

            if platform_fee == 0 && artisan_fee == 0 {
                return (0, 0);
            }

            // Collect the fees in the specified token
            let success = self
                ._collect_fees_in_token(token, payer, amount, platform_fee, artisan_fee, artisan);
            assert(success, 'Token transfer failed');

            // Record the transaction
            let transaction_id = self._record_fee_history(payer, amount, platform_fee, artisan_fee);

            // Update fee totals and tracking
            self._update_fee_totals(token, platform_fee, artisan_fee, payer, artisan);

            self
                .emit(
                    FeeCollected {
                        transaction_id, token, payer, amount, platform_fee, artisan_fee, artisan,
                    },
                );

            (platform_fee, artisan_fee)
        }

        // === Fee Distribution with Token Support ===
        fn distribute_fees(ref self: ComponentState<TContractState>, total_amount: u256) {
            self.distribute_fees_in_token(self.default_token.read(), total_amount);
        }

        fn distribute_fees_in_token(
            ref self: ComponentState<TContractState>, token: ContractAddress, total_amount: u256,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);
            self._assert_token_supported(token);

            assert(total_amount > 0, 'Amount cannot be zero');

            let stakeholder_count = self.stakeholder_count.read();
            assert(stakeholder_count > 0, 'Stakeholder not found');

            // Check if contract has enough balance
            let contract_balance = self.collected_balances.entry(token).read();
            assert(contract_balance >= total_amount, 'Insufficient balance');

            let contract_address = get_contract_address();
            let mut total_distributed = 0;

            let mut i = 0;
            while i < stakeholder_count {
                let stakeholder = self.stakeholder_list.entry(i).read();
                let share_bps = self.stakeholders.entry(stakeholder).read();

                if share_bps > 0 {
                    let distribution_amount = (total_amount * share_bps) / 10000;

                    if distribution_amount > 0 {
                        let success = self
                            ._transfer_token(
                                token, contract_address, stakeholder, distribution_amount,
                            );
                        assert(success, 'Token transfer failed');

                        total_distributed += distribution_amount;

                        self
                            .emit(
                                TokenTransfer {
                                    token,
                                    from: contract_address,
                                    to: stakeholder,
                                    amount: distribution_amount,
                                },
                            );
                    }
                }

                i += 1;
            }

            // Update collected balance
            self.collected_balances.entry(token).write(contract_balance - total_distributed);

            self
                .emit(
                    FeesDistributedInToken {
                        token, total_amount: total_distributed, stakeholder_count,
                    },
                );
        }

        // === Token Management ===
        fn add_supported_token(ref self: ComponentState<TContractState>, token: ContractAddress) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            assert(!self.supported_tokens.entry(token).read(), 'Token already supported');

            self._add_supported_token(token);
            self.emit(TokenAdded { token, by: caller });
        }

        fn remove_supported_token(
            ref self: ComponentState<TContractState>, token: ContractAddress,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            assert(token != self.default_token.read(), 'Cannot remove default token');
            assert(self.supported_tokens.entry(token).read(), 'Token not supported');

            self.supported_tokens.entry(token).write(false);
            self.emit(TokenRemoved { token, by: caller });
        }

        fn is_token_supported(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> bool {
            self.supported_tokens.entry(token).read()
        }

        fn get_supported_token_count(self: @ComponentState<TContractState>) -> u256 {
            self.supported_token_count.read()
        }

        fn get_supported_token(
            self: @ComponentState<TContractState>, index: u256,
        ) -> ContractAddress {
            assert(index < self.supported_token_count.read(), 'Invalid index');
            self.supported_token_list.entry(index).read()
        }

        // === Enhanced Reporting with Token Support ===
        fn get_total_fees_collected_in_token(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> (u256, u256) {
            (
                self.total_platform_fees.entry(token).read(),
                self.total_artisan_fees.entry(token).read(),
            )
        }

        fn get_user_fees_paid_in_token(
            self: @ComponentState<TContractState>, user: ContractAddress, token: ContractAddress,
        ) -> u256 {
            self.user_fees_paid.entry((user, token)).read()
        }

        fn get_artisan_fees_earned_in_token(
            self: @ComponentState<TContractState>, artisan: ContractAddress, token: ContractAddress,
        ) -> u256 {
            self.artisan_fees_earned.entry((artisan, token)).read()
        }

        fn get_collected_balance(
            self: @ComponentState<TContractState>, token: ContractAddress,
        ) -> u256 {
            self.collected_balances.entry(token).read()
        }

        // === Emergency Functions ===
        fn emergency_withdraw(
            ref self: ComponentState<TContractState>, token: ContractAddress, amount: u256,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            assert(amount > 0, 'Amount cannot be zero');

            let current_balance = self.collected_balances.entry(token).read();
            assert(current_balance >= amount, 'Insufficient balance');

            // Update balance
            self.collected_balances.entry(token).write(current_balance - amount);

            // Transfer tokens to treasury
            let config = self.fee_config.read();
            let contract_address = get_contract_address();
            let success = self
                ._transfer_token(token, contract_address, config.treasury_address, amount);
            assert(success, 'Token transfer failed');

            self.emit(EmergencyWithdrawal { token, amount, by: get_caller_address() });
        }

        // === Stakeholder Management ===
        fn add_stakeholder(
            ref self: ComponentState<TContractState>, stakeholder: ContractAddress, share_bps: u256,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            assert(share_bps > 0 && share_bps <= 10000, 'Invalid share percentage');
            assert(self.stakeholders.entry(stakeholder).read() == 0, 'Stakeholder already exists');

            let new_total_shares = self.total_stakeholder_shares.read() + share_bps;
            assert(new_total_shares <= 10000, 'Total shares exceed 100%');

            self.stakeholders.entry(stakeholder).write(share_bps);

            let count = self.stakeholder_count.read();
            self.stakeholder_list.entry(count).write(stakeholder);
            self.stakeholder_count.write(count + 1);
            self.total_stakeholder_shares.write(new_total_shares);

            self.emit(StakeholderAdded { stakeholder, share_bps });
        }

        fn remove_stakeholder(
            ref self: ComponentState<TContractState>, stakeholder: ContractAddress,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let share_bps = self.stakeholders.entry(stakeholder).read();
            assert(share_bps > 0, 'Stakeholder not found');

            self.stakeholders.entry(stakeholder).write(0);
            self.total_stakeholder_shares.write(self.total_stakeholder_shares.read() - share_bps);

            self.emit(StakeholderRemoved { stakeholder });
        }

        fn update_stakeholder_share(
            ref self: ComponentState<TContractState>, stakeholder: ContractAddress, share_bps: u256,
        ) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            let old_share = self.stakeholders.entry(stakeholder).read();
            assert(old_share > 0, 'Stakeholder not found');
            assert(share_bps > 0 && share_bps <= 10000, 'Invalid share percentage');

            let new_total_shares = self.total_stakeholder_shares.read() - old_share + share_bps;
            assert(new_total_shares <= 10000, 'Total shares exceed 100%');

            self.stakeholders.entry(stakeholder).write(share_bps);
            self.total_stakeholder_shares.write(new_total_shares);

            self
                .emit(
                    StakeholderShareUpdated {
                        stakeholder, old_share_bps: old_share, new_share_bps: share_bps,
                    },
                );
        }

        fn get_stakeholder_share(
            self: @ComponentState<TContractState>, stakeholder: ContractAddress,
        ) -> u256 {
            self.stakeholders.entry(stakeholder).read()
        }

        // === Legacy Fee Reporting (for backward compatibility) ===
        fn get_total_fees_collected(self: @ComponentState<TContractState>) -> (u256, u256) {
            self.get_total_fees_collected_in_token(self.default_token.read())
        }

        fn get_user_fees_paid(
            self: @ComponentState<TContractState>, user: ContractAddress,
        ) -> u256 {
            self.get_user_fees_paid_in_token(user, self.default_token.read())
        }

        fn get_artisan_fees_earned(
            self: @ComponentState<TContractState>, artisan: ContractAddress,
        ) -> u256 {
            self.get_artisan_fees_earned_in_token(artisan, self.default_token.read())
        }

        // === Admin Functions ===
        fn pause_fee_collection(ref self: ComponentState<TContractState>) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            self.fee_collection_paused.write(true);
            self.emit(FeeCollectionPaused { by: get_caller_address() });
        }

        fn unpause_fee_collection(ref self: ComponentState<TContractState>) {
            let caller = get_caller_address();
            self._assert_only_owner(caller);

            self.fee_collection_paused.write(false);
            self.emit(FeeCollectionUnpaused { by: get_caller_address() });
        }

        // === Fee History and Reporting ===
        fn get_fee_history_count(self: @ComponentState<TContractState>) -> u256 {
            self.fee_history_count.read()
        }

        fn get_fee_history(self: @ComponentState<TContractState>, index: u256) -> FeeHistory {
            assert(index < self.fee_history_count.read(), 'Invalid history index');
            self.fee_history.entry(index).read()
        }
    }
}
