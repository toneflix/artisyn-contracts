use artisyn::contracts::erc20::{IArtisynTokenDispatcher, IArtisynTokenDispatcherTrait};
use artisyn::contracts::tip::TipManager;
use artisyn::interfaces::tip::{
    ITipManagerDispatcher, ITipManagerDispatcherTrait, Tip, TipCreated, TipFunded, TipResolved,
    TipStatus, TipUpdate, TipUpdated,
};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait,
    cheat_block_timestamp, cheat_caller_address, declare, spy_events, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;

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
    let initial_supply: u256 = 100_000_000;

    token_name.serialize(ref constructor_calldata);
    token_symbol.serialize(ref constructor_calldata);
    initial_supply.serialize(ref constructor_calldata);
    owner().serialize(ref constructor_calldata);

    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    contract_address
}

fn deploy(token: ContractAddress, max: u256) -> ITipManagerDispatcher {
    let contract = declare("TipManager").unwrap().contract_class();
    let mut constructor_calldata: Array<felt252> = array![];
    let fee_percentage: u64 = 50; // 8%
    let supported_tokens: Array<ContractAddress> = array![token];
    let min_target_amount: u256 = 1000;
    let max_target_amount = max;
    let owner: ContractAddress = owner();

    (fee_percentage, supported_tokens, min_target_amount, max_target_amount, owner)
        .serialize(ref constructor_calldata);
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    ITipManagerDispatcher { contract_address }
}

fn setup() -> (ITipManagerDispatcher, IERC20Dispatcher) {
    let token = deploy_token();
    let max_target_amount: u256 = 1_000_000;
    let tip_dispatcher = deploy(token, max_target_amount);
    cheat_caller_address(token, owner(), CheatSpan::TargetCalls(5));
    let token = IERC20Dispatcher { contract_address: token };
    token.transfer(creator(), 1000000);
    // token.transfer(recipient(), 1000000);
    cheat_caller_address(token.contract_address, creator(), CheatSpan::TargetCalls(1));
    token.approve(tip_dispatcher.contract_address, 1000000);
    (tip_dispatcher, token)
}

fn default_tip(token: ContractAddress) -> Tip {
    Tip { recipient: recipient(), target_amount: 100_000, deadline: 10, token }
}

fn tip_integration_context(
    ref funders: Array<ContractAddress>, amount: u256,
) -> (u256, ITipManagerDispatcher, IERC20Dispatcher) {
    let (tip_dispatcher, token) = setup();
    start_cheat_caller_address(tip_dispatcher.contract_address, creator());
    cheat_block_timestamp(tip_dispatcher.contract_address, 1, CheatSpan::TargetCalls(2));
    let tip = default_tip(token.contract_address);
    let id = tip_dispatcher.create(tip);
    stop_cheat_caller_address(tip_dispatcher.contract_address);

    // fund all funders with amount.
    for i in 0..funders.len() {
        let funder = *funders.at(i);
        cheat_caller_address(token.contract_address, owner(), CheatSpan::TargetCalls(1));
        token.transfer(funder, amount);
        cheat_caller_address(token.contract_address, funder, CheatSpan::TargetCalls(1));
        token.approve(tip_dispatcher.contract_address, amount);
        cheat_caller_address(tip_dispatcher.contract_address, funder, CheatSpan::TargetCalls(1));
        tip_dispatcher.fund(id, amount);
    }

    (id, tip_dispatcher, token)
}

fn get_funders() -> Array<ContractAddress> {
    array![
        'funder1'.try_into().unwrap(),
        'funder2'.try_into().unwrap(),
        'funder3'.try_into().unwrap(),
        'funder4'.try_into().unwrap(),
    ]
}

fn feign_default() -> (ITipManagerDispatcher, IERC20Dispatcher) {
    let target: u256 = 100_000;
    let mut funders = get_funders();
    let amount = target / 4;
    let (id, tip_dispatcher, token) = tip_integration_context(ref funders, amount);
    let tip = tip_dispatcher.get_tip(id);
    assert!(tip.funds_raised == target, "Funds raised should match target amount");

    let balance = token.balance_of(recipient());
    assert!(balance == 0, "Recipient balance should be 0 before claiming");
    // here the tip has passed the claim criteria
    // cheat_block_timestamp(tip_dispatcher.contract_address, 11, CheatSpan::Indefinite);
    // cheat_caller_address(tip_dispatcher.contract_address, recipient(), CheatSpan::Indefinite);
    // tip_dispatcher.claim(id);
    (tip_dispatcher, token)
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
#[should_panic(expected: "INVALID TARGET AMOUNT")]
fn test_tip_creation_should_panic_on_invalid_details() {
    let (dispatcher, _) = setup();
    cheat_caller_address(dispatcher.contract_address, creator(), CheatSpan::TargetCalls(1));
    let mut tip = default_tip(1223.try_into().unwrap());
    // reduce the min target amount
    tip.target_amount = 900;
    dispatcher.create(tip);
}

#[test]
#[should_panic(expected: "Tip is > max tip amount of: 1000000")]
fn test_tip_creation_should_panic_on_target_greater_than_threshold() {
    let (dispatcher, _) = setup();
    cheat_caller_address(dispatcher.contract_address, creator(), CheatSpan::TargetCalls(1));
    let mut tip = default_tip(1223.try_into().unwrap());
    // increase the target amount
    tip.target_amount = 2000000;
    dispatcher.create(tip);
}

#[test]
fn test_tip_creation_success_on_target_on_zero_target_threshold() {
    // deploy the contract using 0 as threshold.
    let token = deploy_token();
    let dispatcher = deploy(token, 0);
    cheat_caller_address(dispatcher.contract_address, creator(), CheatSpan::TargetCalls(1));
    let mut tip = default_tip(token);
    tip.target_amount = 2_000_000; // greater than the 1m threshold earlier.
    let id = dispatcher.create(tip);

    assert(id > 0, 'CREATION FAILED');
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

#[test]
fn test_tip_fund_and_claim_success_with_different_funders() {
    let target: u256 = 100_000;
    let mut funders = get_funders();
    let amount = target / 4;
    let (id, tip_dispatcher, token) = tip_integration_context(ref funders, amount);

    let initial_owner_balance = token.balance_of(owner());
    let tip = tip_dispatcher.get_tip(id);
    assert!(tip.funds_raised == target, "Funds raised should match target amount");
    println!("Funds raised 00: {}", tip.funds_raised);
    let balance = token.balance_of(recipient());
    println!("Recipient balance before claiming: {}", balance);
    assert!(balance == 0, "Recipient balance should be 0 before claiming");
    // here the tip has passed the claim criteria
    cheat_block_timestamp(tip_dispatcher.contract_address, 11, CheatSpan::Indefinite);
    cheat_caller_address(tip_dispatcher.contract_address, recipient(), CheatSpan::Indefinite);
    let mut spy = spy_events();
    let contract_balance = token.balance_of(tip_dispatcher.contract_address);
    println!("Contract balance before claiming: {}", contract_balance);
    tip_dispatcher.claim(id);

    let fee = 50 * target / 100;
    let expected_balance = target - fee;
    let new_balance = token.balance_of(recipient());
    assert!(new_balance == expected_balance, "Balance should be greater than zero");
    println!("Recipient balance after claiming: {}", new_balance);

    let expected_owner_balance = initial_owner_balance + fee;
    let new_owner_balance = token.balance_of(owner());
    assert!(
        new_owner_balance == expected_owner_balance,
        "Owner balance should match expected balance after fee deduction",
    );

    let event = TipManager::Event::Resolved(
        TipResolved {
            id,
            created_by: creator(),
            proposed_recipient: recipient(),
            resolved_to: array![recipient()],
            resolved_at: 11,
            amount: expected_balance,
            token: token.contract_address,
            status: 'CLAIMED',
        },
    );

    spy.assert_emitted(@array![(tip_dispatcher.contract_address, event)]);
}

#[test]
#[should_panic(expected: "TIP WITH ID: 1 IS EITHER NOT CLAIMABLE, INVALID, OR HAS BEEN CLAIMED.")]
fn test_tip_claim_should_panic_on_invalid_claim_criteria() {
    // As stated, the only criteria described in this tip integration is the deadline.
    let target: u256 = 100_000;
    let mut funders = get_funders();
    let amount = target / 4;
    let (id, tip_dispatcher, token) = tip_integration_context(ref funders, amount);
    cheat_caller_address(tip_dispatcher.contract_address, recipient(), CheatSpan::Indefinite);
    cheat_block_timestamp(tip_dispatcher.contract_address, 9, CheatSpan::Indefinite);
    // Attempt to claim before deadline should panic
    tip_dispatcher.claim(id);
    assert!(
        token.balance_of(recipient()) == 0, "Recipient balance should still be 0 before deadline",
    );
}

#[test]
fn test_tip_fund_and_claim_success_should_refund_on_voided_tip() {
    let target: u256 = 100_000;
    let mut funders = get_funders();
    let amount = (target / 4) - 2000;
    let (id, tip_dispatcher, token) = tip_integration_context(ref funders, amount);
    let tip = tip_dispatcher.get_tip(id);
    println!("Tip ID: {}, Funds raised: {}", id, tip.funds_raised);

    let balance = token.balance_of(tip_dispatcher.contract_address);
    println!("Contract balance before claiming: {}", balance);

    // Here the tip has passed the claim criteria
    cheat_block_timestamp(tip_dispatcher.contract_address, 11, CheatSpan::Indefinite);
    cheat_caller_address(tip_dispatcher.contract_address, recipient(), CheatSpan::Indefinite);
    let mut spy = spy_events();
    tip_dispatcher.claim(id);
    let balance = token.balance_of(recipient());
    assert!(balance == 0, "Recipient balance should match target amount after claiming");

    // Now we void the tip
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::Indefinite);

    // Check if funds are refunded to funders
    for funder in funders.clone() {
        let balance = token.balance_of(funder);
        println!("Funder x balance after refund: {}", balance);
        assert!(balance == amount, "Funder balance should be refunded to original funding amount");
    }

    let event = TipManager::Event::Resolved(
        TipResolved {
            id,
            created_by: creator(),
            proposed_recipient: recipient(),
            resolved_to: array![*funders.at(3), *funders.at(2), *funders.at(1), *funders.at(0)],
            resolved_at: 11,
            amount: amount * 4,
            token: token.contract_address,
            status: 'VOIDED',
        },
    );

    spy.assert_emitted(@array![(tip_dispatcher.contract_address, event)]);
}

#[test]
#[should_panic(expected: "TIP IS NOT FUNDABLE")]
fn test_tip_funding_should_panic_on_resolved_tip() {
    let (tip_dispatcher, _) = feign_default();
    cheat_caller_address(tip_dispatcher.contract_address, creator(), CheatSpan::Indefinite);
    cheat_block_timestamp(tip_dispatcher.contract_address, 11, CheatSpan::Indefinite);
    tip_dispatcher.fund(1, 1000); // Attempt to fund a resolved tip should panic
}

#[test]
fn test_tip_claim_available_should_resolve_all_pending_tips_related_to_the_caller() { // create multiple tips
// fund all and pass the criteria
// call for recipient, should resolve only the ones related to the recipient,
// which means that tips created for non_recipient() should not be resolved, but shoould be resolved
// when the creator() calls it.
}

