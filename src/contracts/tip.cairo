#[starknet::contract]
pub mod TipManager {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::storage::{
        Map, StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, StoragePath, Mutable
    };
    use crate::interfaces::tip::{Tip, TipNode, TipDetails, ITipManager, TipStatus, TipCreated};
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
    pub enum Event {
        TipCreated: TipCreated,
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
            self.create_tip(tip)
        }

        fn update(ref self: ContractState, id: u256) {
            let node = self.tips.entry(id);
            if update_state(node) {
                return;
            }
        }

        fn create_and_fund(ref self: ContractState, tip: Tip, initial_funding: u256) -> u256 {
            self.create_tip(tip);
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
        fn create_tip(ref self: ContractState, tip: Tip) -> u256 {
            let caller = get_caller_address();
            let timestamp = get_block_timestamp();
            let id = self.tip_count.read() + 1;
            assert!(caller.is_non_zero(), "ZERO CALLER");
            assert!(tip.amount >= self.min_target_amount.read(), "INVALID TARGET AMOUNT");
            let max = self.max_target_amount.read();
            if max > 0 {
                assert!(tip.amount <= max, "Tip is > max tip amount of: {}", max);
            }
            assert!(tip.recipient.is_non_zero(), "RECIPIENT IS ZERO");
            assert!(caller != tip.recipient, "CALLER CANNOT BE RECIPIENT");
            assert!(tip.deadline > timestamp, "INVALID DEADLINE");
            assert!(
                self.supported_tokens.entry(tip.token).read(), "REQUESTED TOKEN IS NOT SUPPORTED",
            );

            let node = self.tips.entry(id);
            node.sender.write(caller);
            node.tip.write(tip);
            node.created_at.write(timestamp);
            node.status.write(TipStatus::Pending);

            self.tip_count.write(id);
            id
        }
    }

    fn update_state(node: StoragePath<Mutable<TipNode>>) -> bool {
        if node.tip.read().deadline <= get_block_timestamp() {

            node.status.write(TipStatus::Void);

            // emit and event, and return
            return true;
        }
        false
    }
}
