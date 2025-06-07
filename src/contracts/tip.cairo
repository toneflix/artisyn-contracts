#[starknet::contract]
pub mod TipManager {
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, Mutable, MutableVecTrait, StoragePath, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess, Vec,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use crate::interfaces::tip::{
        ITipManager, Tip, TipCreated, TipDetails, TipFunded, TipNode, TipResolved, TipStatus,
        TipUpdate, TipUpdated,
    };

    #[storage]
    pub struct Storage {
        tips: Map<u256, TipNode>,
        tip_count: u256,
        supported_tokens: Map<ContractAddress, bool>,
        fee_percentage: u64,
        min_target_amount: u256,
        max_target_amount: u256,
        owner: ContractAddress,
        tips_recipient: Map<ContractAddress, Vec<u256>>,
        tips_creator: Map<ContractAddress, Vec<u256>>,
        supported_tokens_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Created: TipCreated,
        Resolved: TipResolved,
        Updated: TipUpdated,
        Funded: TipFunded,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        fee_percentage: u64,
        supported_tokens: Array<ContractAddress>,
        min_target_amount: u256,
        max_target_amount: u256,
        owner: ContractAddress,
    ) {
        // set max_target_amount as zero to disable it.
        self.fee_percentage.write(fee_percentage);
        self.min_target_amount.write(min_target_amount);
        self.max_target_amount.write(max_target_amount);
        assert(owner.is_non_zero(), 'ZERO OWNER');
        self.owner.write(owner);
        for token in supported_tokens {
            self.supported_tokens.entry(token).write(true);
            self.supported_tokens_count.write(self.supported_tokens_count.read() + 1);
        }
    }

    #[abi(embed_v0)]
    pub impl TipManagerImpl of ITipManager<ContractState> {
        fn create(ref self: ContractState, tip: Tip) -> u256 {
            self.create_tip(tip, 0)
        }

        fn update(ref self: ContractState, id: u256, update: TipUpdate) {
            let node = self.tips.entry(id);
            // do some security checks to assert that this
            let caller = get_caller_address();
            assert!(caller == node.creator.read(), "UNAUTHORIZED CALLER");
            assert!(node.status.read() == TipStatus::Pending, "INVALID TIP");
            if self.update_state(node) {
                return;
            }
            // implement an update here. Rebuild the tip, if any.
            // move all old values for a possible event if entry values are validated successfully
            let mut tip = node.tip.read();
            let mut old_recipient = tip.recipient;
            let mut old_target_amount = tip.target_amount;
            let mut old_deadline = tip.deadline;
            let mut old_token = tip.token;
            let timestamp = get_block_timestamp();
            if let Option::Some(recipient) = update.recipient {
                tip.recipient = recipient;
            }
            if let Option::Some(target_amount) = update.target_amount {
                let funds_raised = node.funds_raised.read();
                assert!(
                    target_amount > funds_raised,
                    "AMOUNT {} <= FUNDS RAISED: {}",
                    target_amount,
                    funds_raised,
                );
                tip.target_amount = target_amount;
            }
            if let Option::Some(deadline) = update.deadline {
                tip.deadline = deadline;
            }
            if let Option::Some(token) = update.token {
                tip.token = token;
            }

            self.validate_tip(tip, caller, timestamp);
            node.tip.write(tip);

            let tip_updated = TipUpdated {
                id,
                updated_by: caller,
                updated_at: timestamp,
                recipient: (old_recipient, tip.recipient),
                target_amount: (old_target_amount, tip.target_amount),
                deadline: (old_deadline, tip.deadline),
                token: (old_token, tip.token),
            };
            self.emit(tip_updated);
        }

        fn create_and_fund(ref self: ContractState, tip: Tip, initial_funding: u256) -> u256 {
            self.create_tip(tip, initial_funding)
        }
        /// Here, anybody can fund a particular tip, except the recipient.
        fn fund(ref self: ContractState, id: u256, amount: u256) {
            let caller = get_caller_address();
            assert!(caller.is_non_zero(), "ZERO CALLER");
            let node = self.tips.entry(id);
            assert!(node.status.read() == TipStatus::Pending, "INVALID TIP WITH ID");
            if self.update_state(node) {
                return;
            }

            let tip = node.tip.read();
            assert!(caller != tip.recipient, "CALLER CANNOT BE RECIPIENT");
            let dispatcher = IERC20Dispatcher { contract_address: tip.token };
            assert!(dispatcher.balance_of(caller) >= amount, "INSUFFICIENT BALANCE");
            self.fund_tip(node, amount, tip, dispatcher, caller);
        }

        fn claim(ref self: ContractState, id: u256) {
            let caller = get_caller_address();
            assert!(caller.is_non_zero(), "ZERO CALLER");
            let node = self.tips.entry(id);

            assert!(
                self.update_state(node),
                "TIP WITH ID: {} IS EITHER NOT CLAIMABLE, INVALID, OR HAS BEEN CLAIMED.",
                id,
            );
        }

        fn claim_available(ref self: ContractState) {
            // this performs claim for all available ids, and updates each state until
            // let mut unclaimmable = array![];
            let caller = get_caller_address();
            let tips_recipient = self.tips_recipient.entry(caller);
            let max = tips_recipient.len();
            let tips_creator = self.tips_creator.entry(caller);
            for _ in 0..max {
                let id = tips_recipient.pop().unwrap();
                let node = self.tips.entry(id);
                if node.status.read() != TipStatus::Pending {
                    continue;
                }
                if !self.update_state(node) {
                    tips_recipient.push(id);
                }
            }

            let max = tips_creator.len();
            for _ in 0..max {
                let id = tips_creator.pop().unwrap();
                let node = self.tips.entry(id);
                if node.status.read() == TipStatus::Pending && !self.update_state(node) {
                    tips_recipient.push(id);
                }
            }
        }

        fn get_tip(self: @ContractState, id: u256) -> TipDetails {
            let node = self.tips.entry(id);
            let tip = node.tip.read();
            assert!(tip != Default::default(), "TIP DOES NOT EXIST");
            TipDetails {
                creator: node.creator.read(),
                recipient: tip.recipient,
                target_amount: tip.target_amount,
                deadline: tip.deadline,
                status: node.status.read(),
                funds_raised: node.funds_raised_ref.read(),
            }
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn create_tip(ref self: ContractState, tip: Tip, amount: u256) -> u256 {
            let Tip { recipient, target_amount, deadline, token } = tip;
            let caller = get_caller_address();
            let dispatcher = IERC20Dispatcher { contract_address: token };
            if amount > 0 {
                let balance = dispatcher.balance_of(caller);
                assert!(balance >= amount, "INSUFFICIENT FUNDS");
            }
            let created_at = get_block_timestamp();
            let id = self.tip_count.read() + 1;
            assert!(caller.is_non_zero(), "ZERO CALLER");
            self.validate_tip(tip, caller, created_at);

            let node = self.tips.entry(id);

            // any failure in the transaction reverts, thus, the tip will not proceed to be created
            if amount > 0 {
                self.fund_tip(node, amount, tip, dispatcher, caller);
            }
            node.id.write(id);
            node.creator.write(caller);
            node.tip.write(tip);
            node.created_at.write(created_at);
            node.status.write(TipStatus::Pending);
            self.tips_creator.entry(caller).push(id);
            self.tips_recipient.entry(recipient).push(id);

            let tip_created = TipCreated {
                id, created_by: caller, recipient, created_at, deadline, target_amount, token,
            };
            self.emit(tip_created);

            self.tip_count.write(id);
            id
        }

        fn update_state(ref self: ContractState, node: StoragePath<Mutable<TipNode>>) -> bool {
            let caller = get_caller_address();
            let tip = node.tip.read();
            let mut status = 'CLAIMED';

            let Tip { recipient, target_amount, deadline, token } = tip;
            let mut resolved_to = array![];
            let mut resolved = node.status.read() != TipStatus::Pending;
            let mut amount = node.funds_raised.read();
            let dispatcher = IERC20Dispatcher { contract_address: node.tip.read().token };
            if deadline <= get_block_timestamp() && !resolved {
                if amount == target_amount {
                    // initialize a transfer to the target
                    // for nice user experience, we only want to collect a fee when the tip is
                    // successful
                    let fee_percentage = self.fee_percentage.read();
                    let fee = amount * fee_percentage.into() / 100;
                    amount -= fee;
                    dispatcher.transfer(self.owner.read(), fee);

                    node.status.write(TipStatus::Claimed);
                    dispatcher.transfer(recipient, amount);
                    node.funds_raised.write(0);
                    resolved_to.append(recipient);
                } else {
                    // for each funder, refund appropriately
                    let funders = node.funders_vec;

                    while let Option::Some(funder) = funders.pop() {
                        let funds = node.funders.entry(funder).read();
                        dispatcher.transfer(funder, amount);
                        node.funders.entry(funder).write(0);
                        node.funds_raised.write(node.funds_raised.read() - funds);
                        resolved_to.append(funder);
                    }
                    node.status.write(TipStatus::Void);
                    status = 'VOID';
                }
                resolved = true;
            }
            if resolved {
                // update necessary node variables
                let proposed_recipient = recipient;
                let resolved_at = get_block_timestamp();
                let tip_resolved = TipResolved {
                    id: node.id.read(),
                    created_by: caller,
                    proposed_recipient,
                    resolved_at,
                    resolved_to,
                    amount,
                    token,
                    status,
                };
                self.emit(tip_resolved);
            }
            resolved
        }

        fn fund_tip(
            ref self: ContractState,
            node: StoragePath<Mutable<TipNode>>,
            mut amount: u256,
            tip: Tip,
            dispatcher: IERC20Dispatcher,
            from: ContractAddress,
        ) {
            if amount > tip.target_amount {
                // offset and deduct only the necessary amount
                amount = tip.target_amount;
            }
            let previous = node.funds_raised.read();
            dispatcher.transfer_from(from, get_contract_address(), amount);
            node.funds_raised.write(previous + amount);
            node.funds_raised_ref.write(previous + amount);
            let previous = node.funders.entry(from).read();
            node.funders.entry(from).write(previous + amount);

            let funded_at = get_block_timestamp();

            let tip_funded = TipFunded {
                id: node.id.read(), funded_by: from, amount, token: tip.token, funded_at,
            };
            self.emit(tip_funded);
        }

        fn validate_tip(
            ref self: ContractState, tip: Tip, caller: ContractAddress, timestamp: u64,
        ) {
            let Tip { recipient, target_amount, deadline, token } = tip;
            assert!(target_amount >= self.min_target_amount.read(), "INVALID TARGET AMOUNT");
            let max = self.max_target_amount.read();
            // if max > 0 { assert!(target_amount <= max, "Tip is > max tip amount of: {}", max);}
            assert!(max == 0 || target_amount <= max, "Tip is > max tip amount of: {}", max);
            assert!(recipient.is_non_zero(), "RECIPIENT IS ZERO");
            assert!(caller != recipient, "CALLER CANNOT BE RECIPIENT");
            assert!(deadline > timestamp, "INVALID DEADLINE");
            assert!(
                self.supported_tokens_count.read() == 0
                    || self.supported_tokens.entry(token).read(),
                "REQUESTED TOKEN IS NOT SUPPORTED",
            );
        }
    }
}
