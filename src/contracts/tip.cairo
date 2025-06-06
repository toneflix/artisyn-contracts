#[starknet::contract]
pub mod TipManager {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{
        Map, StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, StoragePath,
        Mutable, MutableVecTrait,
    };
    use crate::interfaces::tip::{
        Tip, TipNode, TipDetails, ITipManager, TipStatus, TipCreated, TipResolved,
    };
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use core::num::traits::Zero;

    #[storage]
    pub struct Storage {
        tips: Map<u256, TipNode>,
        tip_count: u256,
        supported_tokens: Map<ContractAddress, bool>,
        fee_percentage: u64,
        min_target_amount: u256,
        max_target_amount: u256,
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TipCreated: TipCreated,
        TipResolved: TipResolved,
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
        }
    }

    #[abi(embed_v0)]
    pub impl TipManagerImpl of ITipManager<ContractState> {
        fn create(ref self: ContractState, tip: Tip) -> u256 {
            self.create_tip(tip, 0)
        }

        fn update(ref self: ContractState, id: u256) {
            let node = self.tips.entry(id);
            if self.update_state(node) {
                return;
            }
            // implement an update here.
        }

        fn create_and_fund(ref self: ContractState, tip: Tip, initial_funding: u256) -> u256 {
            self.create_tip(tip, initial_funding)
        }
        /// Here, anybody can fund a particular tip, except the recipient.
        fn fund(ref self: ContractState, id: u256) {}
        fn claim(ref self: ContractState, id: u256) {}
        fn claim_available(ref self: ContractState) {}
        fn get_tip(self: @ContractState, id: u256) -> TipDetails {
            Default::default()
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
            assert!(target_amount >= self.min_target_amount.read(), "INVALID TARGET AMOUNT");
            let max = self.max_target_amount.read();
            if max > 0 {
                assert!(target_amount <= max, "Tip is > max tip amount of: {}", max);
            }
            assert!(recipient.is_non_zero(), "RECIPIENT IS ZERO");
            assert!(caller != recipient, "CALLER CANNOT BE RECIPIENT");
            assert!(deadline > created_at, "INVALID DEADLINE");
            assert!(self.supported_tokens.entry(token).read(), "REQUESTED TOKEN IS NOT SUPPORTED");

            let node = self.tips.entry(id);

            // any failure in the transaction reverts, thus, the tip will not proceed to be created
            if amount > 0 {
                self.fund_tip(node, amount, tip, dispatcher, caller);
            }
            node.id.write(id);
            node.sender.write(caller);
            node.tip.write(tip);
            node.created_at.write(created_at);
            node.status.write(TipStatus::Pending);

            let tip_created = TipCreated {
                created_by: caller, recipient, created_at, deadline, target_amount, token,
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
            let mut resolved_to = array![]; // we assume it's the recipient
            let mut resolved = false;
            let mut amount = node.funds_raised.read();
            let dispatcher = IERC20Dispatcher { contract_address: node.tip.read().token };
            if deadline <= get_block_timestamp() {
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

                    for i in 0..funders.len() {
                        let funder = funders.at(i).read();
                        let funds = node.funders.entry(funder).read();
                        dispatcher.transfer(funder, amount);
                        node.funders.entry(funder).write(0);
                        node.funds_raised.write(node.funds_raised.read() - funds);
                        resolved_to.append(funder);
                    };
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
            dispatcher.transfer_from(from, get_contract_address(), amount);
            node.funds_raised.write(amount);
            node.funds_raised_ref.write(amount);
            node.funders.entry(caller);
        }
    }
}
