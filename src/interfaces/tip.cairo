use starknet::ContractAddress;
use core::num::traits::Zero;
use starknet::storage::{Map, Vec};

// Fork & Branch: Fork the repository and create a dedicated branch for this feature.

// Core Features:

// Tip Creation and Funding: Implement functions to create tips and fund them.
// Escrow Holding Mechanism: Securely hold tip funds in escrow until release conditions are met.
// Verification for Tip Claims: Ensure proper checks before allowing artisans to claim tips.
// Expiration and Refund Logic: Incorporate mechanisms to handle tip expiration and refund the funds
// if not claimed.
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
    fn update(ref self: TContractState, id: u256);
    fn create_and_fund(ref self: TContractState, tip: Tip, initial_funding: u256) -> u256;
    /// Here, anybody can fund a particular tip, except the recipient.
    fn fund(ref self: TContractState, id: u256);
    fn claim(ref self: TContractState, id: u256);
    fn claim_available(ref self: TContractState);
    fn get_tip(self: @TContractState, id: u256) -> TipDetails;
}

impl ContractAddressDefault of Default<ContractAddress> {
    #[inline(always)]
    fn default() -> ContractAddress {
        Zero::zero()
    }
}

#[derive(Drop, Copy, Serde, Default)]
pub struct TipDetails {
    pub sender: ContractAddress,
    pub recipient: u256,
    pub deadine: u64,
    pub status: TipStatus,
    pub funds_raised: u256,
}

#[derive(Drop, Copy, Serde, Default, starknet::Store)]
pub struct Tip {
    pub recipient: ContractAddress,
    pub target_amount: u256,
    pub deadline: u64,
    pub token: ContractAddress,
}

#[starknet::storage_node]
pub struct TipNode {
    pub id: u256,
    pub sender: ContractAddress,
    pub tip: Tip,
    pub created_at: u64,
    pub status: TipStatus,
    pub funds_raised: u256, // store the state
    pub funds_raised_ref: u256, // store for the history
    pub funders: Map<ContractAddress, u256>,
    pub funders_vec: Vec<ContractAddress>,
}

#[derive(Drop, Copy, PartialEq, Serde, Default, starknet::Store)]
pub enum TipStatus {
    #[default]
    Void,
    Pending,
    Claimed,
}

#[derive(Drop, starknet::Event)]
pub struct TipCreated {
    pub created_by: ContractAddress,
    pub recipient: ContractAddress,
    pub created_at: u64,
    pub deadline: u64,
    pub target_amount: u256,
    pub token: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct TipResolved {
    pub id: u256,
    pub created_by: ContractAddress, // the creator of the tip
    pub proposed_recipient: ContractAddress, // the address who the tip was created for
    pub resolved_to: Array<ContractAddress>, // the actual recipient of the generated funds
    pub resolved_at: u64,
    pub amount: u256,
    pub token: ContractAddress,
    pub status: felt252,
}
