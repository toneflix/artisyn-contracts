#[starknet::contract]
pub mod TipManager {
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    pub struct Storage {

    }

    #[constructor]
    fn constructor(ref self: ContractState, fee_percentage: u64, supported_tokens: Array<ContractAddress>) {

    }
}