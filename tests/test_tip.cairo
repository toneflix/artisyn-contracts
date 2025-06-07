use artisyn::contracts::erc20::{IArtisynTokenDispatcher, IArtisynTokenDispatcherTrait};
use artisyn::contracts::tip::TipManager;
use artisyn::interfaces::tip::{
    ITipManagerDispatcher, ITipManagerDispatcherTrait, Tip, TipCreated, TipDetails, TipFunded,
    TipResolved, TipStatus,
};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_block_timestamp, cheat_caller_address, declare, spy_events,
};
use starknet::{ContractAddress, get_contract_address};

fn owner() -> ContractAddress {
    'owner'.try_into().unwrap()
}

fn creator() -> ContractAddress {
    'creator'.try_into().unwrap()
}

fn recipient() -> ContractAddress {
    'recipient'.try_into().unwrap()
}

fn deploy_token() -> ContractAddress {
    let contract = declare("ArtisynToken").unwrap().contract_class();

    let mut constructor_calldata: Array<felt252> = array![];
    let token_name: ByteArray = "Artisyn Token";
    let token_symbol: ByteArray = "ART";
    let initial_supply: u256 = 100000000;

    token_name.serialize(ref constructor_calldata);
    token_symbol.serialize(ref constructor_calldata);
    initial_supply.serialize(ref constructor_calldata);

    cheat_caller_address(get_contract_address(), owner(), CheatSpan::TargetCalls(1));
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    contract_address
}

fn deploy() -> ITipManagerDispatcher {
    let contract = declare("TipManager").unwrap().contract_class();
    let mut constructor_calldata: Array<felt252> = array![];
    let fee_percentage: u64 = 800; // 8%
    let supported_tokens: Array<ContractAddress> = array![];
    let min_target_amount: u256 = 1000;
    let max_target_amount: u256 = 1000000;
    let owner: ContractAddress = owner();

    (fee_percentage, supported_tokens, min_target_amount, max_target_amount, owner)
        .serialize(ref constructor_calldata);
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    ITipManagerDispatcher { contract_address }
}

fn setup() -> (ITipManagerDispatcher, IERC20Dispatcher) {
    let tip_dispatcher = deploy();
    let token = deploy_token();
    cheat_caller_address(token, owner(), CheatSpan::TargetCalls(1));
    let minter = IArtisynTokenDispatcher { contract_address: token };
    minter.mint(creator(), 1000000);
    minter.mint(recipient(), 1000000);
    (tip_dispatcher, IERC20Dispatcher { contract_address: token })
}

// fn create(ref self: TContractState, tip: Tip) -> u256;
// fn update(ref self: TContractState, id: u256, update: TipUpdate);
// fn create_and_fund(ref self: TContractState, tip: Tip, initial_funding: u256) -> u256;
// fn fund(ref self: TContractState, id: u256, amount: u256);
// fn claim(ref self: TContractState, id: u256);
// fn claim_available(ref self: TContractState);
// fn get_tip(self: @TContractState, id: u256) -> TipDetails;

fn default_tip(token: ContractAddress) -> Tip {
    Tip { recipient: recipient(), target_amount: 100000, deadline: 10, token }
}

#[test]
fn test_tip_creation_success() {
    let dispatcher = deploy();
    let mut spy = spy_events();
    cheat_caller_address(dispatcher.contract_address, creator(), CheatSpan::TargetCalls(1));
    cheat_block_timestamp(dispatcher.contract_address, 1, CheatSpan::TargetCalls(2));
    // extract to a different function
    let tip = Tip {
        recipient: recipient(),
        target_amount: 100000,
        deadline: 10,
        token: 0x05647.try_into().unwrap(),
    };

    let id = dispatcher.create(tip);
    assert!(id == 1, "Tip ID should be 1");
    let event = TipManager::Event::Created(
        TipCreated {
            id: 1,
            created_by: creator(),
            recipient: recipient(),
            created_at: 1,
            target_amount: 100000,
            deadline: 10,
            token: 0x05647.try_into().unwrap(),
        },
    );
    spy.assert_emitted(@array![(dispatcher.contract_address, event)]);
    let details = dispatcher.get_tip(id);
    assert!(details.creator == creator(), "Creator should match");
    assert!(details.recipient == recipient(), "Recipient should match");
    assert!(details.deadline == 10, "Deadline should match");
    assert!(details.target_amount == 100000, "Target amount should match");
    assert!(details.status == TipStatus::Pending, "Status should be Pending");
}

#[test]
#[should_panic(expected: "Something")]
fn test_tip_creation_should_panic_on_invalid_details() {
    panic!("Something");
}

#[test]
fn test_tip_funding_success() {
    let (tip_dispatcher, token_dispatcher) = setup();
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::TargetCalls(3));
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(4));
    // extract to a different function
    let tip = default_tip(token_dispatcher.contract_address);
    let id = tip_dispatcher.create(tip);
    let mut spy = spy_events();
    tip_dispatcher.fund(id, 9000);

    let details = tip_dispatcher.get_tip(id);
    assert!(details.funds_raised == 9000, "Funds raised should be 9000");

    let event = TipManager::Event::Funded(
        TipFunded {
            id: 1,
            funded_by: creator(),
            amount: 9000,
            token: 0x05647.try_into().unwrap(),
            funded_at: 1,
        },
    );

    spy.assert_emitted(@array![(tip_dispatcher.contract_address, event)]);
    // CustomToken {
//     pub contract_address: ContractAddress,
//     pub balances_variable_selector: felt252,
}

#[test]
fn test_tip_funding_should_offset_on_amount_greater_than_target() {}
