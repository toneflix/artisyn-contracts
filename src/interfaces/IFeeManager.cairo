use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store, Clone)]
pub struct FeeConfig {
    pub platform_fee_bps: u256, // Platform fee in basis points (100 = 1%)
    pub artisan_fee_bps: u256, // Artisan fee in basis points
    pub max_fee_bps: u256, // Maximum total fee allowed
    pub min_transaction_amount: u256, // Minimum transaction amount for fees
    pub default_token: ContractAddress,
    pub treasury_address: ContractAddress, // Address where platform fees are sent
    pub is_active: bool // Whether fee collection is active
}

#[derive(Drop, Serde, starknet::Store)]
pub struct FeeDistribution {
    pub stakeholder: ContractAddress,
    pub share_bps: u256 // Share in basis points
}

#[derive(Drop, Serde, starknet::Store)]
pub struct FeeHistory {
    pub transaction_id: u256,
    pub payer: ContractAddress,
    pub amount: u256,
    pub platform_fee: u256,
    pub artisan_fee: u256,
    pub timestamp: u64,
}

#[starknet::interface]
pub trait IFeeManager<TState> {
    // === Fee Configuration ===
    fn set_fee_config(ref self: TState, config: FeeConfig);
    fn get_fee_config(self: @TState) -> FeeConfig;
    fn update_platform_fee(ref self: TState, fee_bps: u256);
    fn update_artisan_fee(ref self: TState, fee_bps: u256);
    fn update_treasury_address(ref self: TState, treasury: ContractAddress);
    fn set_fee_active(ref self: TState, active: bool);

    // === Fee Calculation ===
    fn calculate_fees(self: @TState, amount: u256) -> (u256, u256); // (platform_fee, artisan_fee)
    fn calculate_total_fee(self: @TState, amount: u256) -> u256;
    fn get_net_amount(self: @TState, gross_amount: u256) -> u256;

    // === Fee Collection ===
    fn collect_fees(
        ref self: TState, payer: ContractAddress, amount: u256, artisan: ContractAddress,
    ) -> (u256, u256); // Returns (platform_fee_collected, artisan_fee_collected)

    fn collect_fees_in_token(
        ref self: TState,
        token: ContractAddress,
        payer: ContractAddress,
        amount: u256,
        artisan: ContractAddress,
    ) -> (u256, u256);

    // === Fee Distribution ===
    fn add_stakeholder(ref self: TState, stakeholder: ContractAddress, share_bps: u256);
    fn remove_stakeholder(ref self: TState, stakeholder: ContractAddress);
    fn update_stakeholder_share(ref self: TState, stakeholder: ContractAddress, share_bps: u256);
    fn distribute_fees(ref self: TState, total_amount: u256);
    fn distribute_fees_in_token(ref self: TState, token: ContractAddress, total_amount: u256);
    fn get_stakeholder_share(self: @TState, stakeholder: ContractAddress) -> u256;

    // === Token Management ===
    fn add_supported_token(ref self: TState, token: ContractAddress);
    fn remove_supported_token(ref self: TState, token: ContractAddress);
    fn is_token_supported(self: @TState, token: ContractAddress) -> bool;
    fn get_supported_token_count(self: @TState) -> u256;
    fn get_supported_token(self: @TState, index: u256) -> ContractAddress;

    // === Fee History and Reporting ===
    fn get_fee_history_count(self: @TState) -> u256;
    fn get_fee_history(self: @TState, index: u256) -> FeeHistory;
    fn get_total_fees_collected(self: @TState) -> (u256, u256); // (platform_total, artisan_total)
    fn get_total_fees_collected_in_token(self: @TState, token: ContractAddress) -> (u256, u256);
    fn get_user_fees_paid(self: @TState, user: ContractAddress) -> u256;
    fn get_user_fees_paid_in_token(
        self: @TState, user: ContractAddress, token: ContractAddress,
    ) -> u256;
    fn get_artisan_fees_earned(self: @TState, artisan: ContractAddress) -> u256;
    fn get_artisan_fees_earned_in_token(
        self: @TState, artisan: ContractAddress, token: ContractAddress,
    ) -> u256;

    // === Admin Functions ===
    fn pause_fee_collection(ref self: TState);
    fn unpause_fee_collection(ref self: TState);
    fn emergency_withdraw(ref self: TState, token: ContractAddress, amount: u256);
    fn get_collected_balance(self: @TState, token: ContractAddress) -> u256;
}
