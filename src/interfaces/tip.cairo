use core::num::traits::Zero;
use starknet::ContractAddress;
use starknet::storage::{Map, Vec};

#[starknet::interface]
pub trait ITipManager<TContractState> {
    fn create(ref self: TContractState, tip: Tip) -> u256;
    fn update(ref self: TContractState, id: u256, update: TipUpdate);
    fn create_and_fund(ref self: TContractState, tip: Tip, initial_funding: u256) -> u256;
    fn fund(ref self: TContractState, id: u256, amount: u256);
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
    pub creator: ContractAddress,
    pub recipient: ContractAddress,
    pub deadline: u64,
    pub target_amount: u256,
    pub status: TipStatus,
    pub funds_raised: u256,
}

#[derive(Drop, Copy, Serde, Default, PartialEq, starknet::Store)]
pub struct Tip {
    pub recipient: ContractAddress,
    pub target_amount: u256,
    pub deadline: u64,
    pub token: ContractAddress,
}

#[derive(Drop, Copy, Serde, Default)]
pub struct TipUpdate {
    pub recipient: Option<ContractAddress>,
    pub target_amount: Option<u256>,
    pub deadline: Option<u64>, // here, the token cannot be changed.
    pub token: Option<ContractAddress>,
}

#[starknet::storage_node]
pub struct TipNode {
    pub id: u256,
    pub creator: ContractAddress,
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
    pub id: u256,
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

// each tuple represents (previous_value, new_value) if applicable
#[derive(Drop, starknet::Event)]
pub struct TipUpdated {
    pub id: u256,
    pub updated_by: ContractAddress,
    pub updated_at: u64,
    pub recipient: (ContractAddress, ContractAddress),
    pub target_amount: (u256, u256),
    pub deadline: (u64, u64),
    pub token: (ContractAddress, ContractAddress),
}

#[derive(Drop, starknet::Event)]
pub struct TipFunded {
    pub id: u256,
    pub funded_by: ContractAddress,
    pub amount: u256,
    pub token: ContractAddress,
    pub funded_at: u64,
}
