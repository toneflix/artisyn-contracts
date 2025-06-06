use starknet::ContractAddress;
use core::num::traits::Zero;

// Fork & Branch: Fork the repository and create a dedicated branch for this feature.

// Core Features:

// Tip Creation and Funding: Implement functions to create tips and fund them.
// Escrow Holding Mechanism: Securely hold tip funds in escrow until release conditions are met.
// Verification for Tip Claims: Ensure proper checks before allowing artisans to claim tips.
// Expiration and Refund Logic: Incorporate mechanisms to handle tip expiration and refund the funds if not claimed.
// Fee Calculation & Distribution: Implement fee calculations and distribute fees accordingly.
// Events & Logging:

// Add events for all tip state changes to facilitate transparency and debugging.
// Administration & Dispute Resolution:

// Create admin functions to allow dispute resolution when necessary.
// Guidelines:

// Security: Ensure the design prioritizes the security of escrowed funds.
// Verification: Implement thorough verification checks.
// Documentation: Document escrow parameters and the tip claim process.
// Testing: Write extensive unit tests covering all scenarios.

#[starknet::interface]
pub trait ITipManager<TContractState> {
    fn create(ref self: TContractState, tip: Tip) -> u256;
    fn create_and_fund(ref self: TContractState, tip: Tip, initial_amount: u256);
    /// Here, anybody can fund a particular tip.
    fn fund(ref self: TContractState, id: u256);
    fn claim(ref self: TContractState, id: u256);
    fn claim_available(ref self: TContractState);
}

impl ContractAddressDefault of Default<ContractAddress> {
    #[inline(always)]
    fn default() -> ContractAddress {
        Zero::zero()
    }
}

// struct Tip {
//     address sender;
//     address recipient;
//     uint256 amount;
//     uint256 timestamp;
//     bool claimed;
// }
#[derive(Drop, Copy, Serde, Default, starknet::Store)]
pub struct Tip {
    pub recipient: ContractAddress,
    pub amount: u256,
    pub deadline: u64,
}

#[starknet::storage_node]
pub struct TipNode {
    pub sender: ContractAddress,
    pub tip: Tip,
    pub timestamnp: u64,
    pub status: TipStatus,
}

#[derive(Drop, Copy, PartialEq, Serde, Default, starknet::Store)]
pub enum TipStatus {
    #[default]
    Void,
    Pending,
    Claimed,
}