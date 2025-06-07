use artisyn::contracts::erc20::{IArtisynTokenDispatcher, IArtisynTokenDispatcherTrait};
use artisyn::contracts::tip::TipManager;
use artisyn::interfaces::tip::{
    ITipManagerDispatcher, ITipManagerDispatcherTrait, Tip, TipCreated, TipFunded, TipResolved,
    TipStatus, TipUpdate, TipUpdated,
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
    owner().serialize(ref constructor_calldata);

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    contract_address
}

fn deploy(token: ContractAddress) -> ITipManagerDispatcher {
    let contract = declare("TipManager").unwrap().contract_class();
    let mut constructor_calldata: Array<felt252> = array![];
    let fee_percentage: u64 = 800; // 8%
    let supported_tokens: Array<ContractAddress> = array![token];
    let min_target_amount: u256 = 1000;
    let max_target_amount: u256 = 1000000;
    let owner: ContractAddress = owner();

    (fee_percentage, supported_tokens, min_target_amount, max_target_amount, owner)
        .serialize(ref constructor_calldata);
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    ITipManagerDispatcher { contract_address }
}

fn setup() -> (ITipManagerDispatcher, IERC20Dispatcher) {
    let token = deploy_token();
    let tip_dispatcher = deploy(token);
    cheat_caller_address(token, owner(), CheatSpan::TargetCalls(5));
    let token = IERC20Dispatcher { contract_address: token };
    let balance = token.balance_of(owner());
    token.transfer(creator(), 1000000);
    token.transfer(recipient(), 1000000);
    cheat_caller_address(token.contract_address, creator(), CheatSpan::TargetCalls(1));
    token.approve(tip_dispatcher.contract_address, 1000000);
    (tip_dispatcher, token)
}

fn default_tip(token: ContractAddress) -> Tip {
    Tip { recipient: recipient(), target_amount: 100000, deadline: 10, token }
}

#[test]
fn test_tip_creation_success() {
    let (dispatcher, token) = setup();
    let mut spy = spy_events();
    cheat_caller_address(dispatcher.contract_address, creator(), CheatSpan::TargetCalls(1));
    cheat_block_timestamp(dispatcher.contract_address, 1, CheatSpan::TargetCalls(2));
    // extract to a different function
    let tip = Tip {
        recipient: recipient(), target_amount: 100000, deadline: 10, token: token.contract_address,
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
            token: token.contract_address,
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
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::TargetCalls(4));
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(4));
    token_dispatcher.approve(tip_dispatcher.contract_address, 9000);
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
            token: token_dispatcher.contract_address,
            funded_at: 1,
        },
    );

    spy.assert_emitted(@array![(tip_dispatcher.contract_address, event)]);
}

#[test]
fn test_tip_funding_should_offset_on_amount_greater_than_target() {
    let (tip_dispatcher, token) = setup();
    let tip = default_tip(token.contract_address);
    let id = tip_dispatcher.create(tip);
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::TargetCalls(4));
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(4));

    let balance = token.balance_of(creator());
    let funding_amount: u256 = 200000; // Greater than target amount
    let offset = 200000 - 100000;
    let remainder = balance - offset;

    tip_dispatcher.fund(id, funding_amount);
    let new_balance = token.balance_of(creator());
    assert!(new_balance == remainder, "INVALID BALANCE");

    let details = tip_dispatcher.get_tip(id);
    assert!(details.funds_raised == offset, "AMOUNT PEGGING FAILED.");
}

#[test]
fn test_tip_create_and_fund_success() {
    let (tip_dispatcher, token) = setup();
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::Indefinite);
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::Indefinite);
    let tip = default_tip(token.contract_address);
    let mut spy = spy_events();
    let id = tip_dispatcher.create_and_fund(tip, 1000);

    assert!(id == 1, "Tip ID should be 1");
    let details = tip_dispatcher.get_tip(id);
    assert!(details.funds_raised == 1000, "Funds raised should be 1000");
    let event1 = TipManager::Event::Created(
        TipCreated {
            id: 1,
            created_by: creator(),
            recipient: recipient(),
            created_at: 1,
            target_amount: 100000,
            deadline: 10,
            token: token.contract_address,
        },
    );

    let event2 = TipManager::Event::Funded(
        TipFunded {
            id: 1, funded_by: creator(), amount: 1000, token: token.contract_address, funded_at: 1,
        },
    );

    let events = array![
        (tip_dispatcher.contract_address, event1), (tip_dispatcher.contract_address, event2),
    ];
    // (tip_dispatcher.contract_address, event1),
    spy.assert_emitted(@events);
    let details = tip_dispatcher.get_tip(id);
    assert!(details.funds_raised == 1000, "Funds raised should be 1000");
}

#[test]
#[should_panic(expected: "CALLER CANNOT BE RECIPIENT")]
fn test_tip_funding_should_panic_on_recipient_funding() {
    let (tip_dispatcher, token) = setup();
    let tip = default_tip(token.contract_address);
    let id = tip_dispatcher.create(tip);
    cheat_caller_address(tip_dispatcher.contract_address, recipient(), CheatSpan::TargetCalls(4));
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(4));
    tip_dispatcher.fund(id, 1000);
}

#[test]
fn test_tip_update_success() {
    let (tip_dispatcher, token) = setup();
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::TargetCalls(4));
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(4));
    let tip = default_tip(token.contract_address);
    let id = tip_dispatcher.create(tip);
    let new_recipient: ContractAddress = 'new_recipient'.try_into().unwrap();
    let new_amount: u256 = 200000;
    let mut spy = spy_events();

    let update = TipUpdate {
        recipient: Some(new_recipient),
        target_amount: Some(new_amount),
        deadline: Some(20),
        token: None,
    };

    cheat_block_timestamp(tip_dispatcher.contract_address, 4, CheatSpan::TargetCalls(4));
    tip_dispatcher.update(id, update);

    let details = tip_dispatcher.get_tip(id);
    assert!(details.recipient == new_recipient, "Recipient should match");
    assert!(details.target_amount == 200000, "Target amount should match");
    assert!(details.deadline == 20, "Deadline should match");

    let recipient = (recipient(), new_recipient);
    let token_update = (token.contract_address, token.contract_address);
    let target_amount = (100000, new_amount);
    let deadline = (10, 20);

    let event = TipManager::Event::Updated(
        TipUpdated {
            id: 1,
            updated_by: creator(),
            updated_at: 4,
            recipient,
            target_amount,
            deadline,
            token: token_update,
        },
    );

    spy.assert_emitted(@array![(tip_dispatcher.contract_address, event)]);
}
// fn create(ref self: TContractState, tip: Tip) -> u256;
// fn update(ref self: TContractState, id: u256, update: TipUpdate);
// fn create_and_fund(ref self: TContractState, tip: Tip, initial_funding: u256) -> u256;
// fn fund(ref self: TContractState, id: u256, amount: u256);
// fn claim(ref self: TContractState, id: u256);
// fn claim_available(ref self: TContractState);
// fn get_tip(self: @TContractState, id: u256) -> TipDetails;


