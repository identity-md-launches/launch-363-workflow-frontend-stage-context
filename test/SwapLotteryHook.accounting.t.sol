// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {LotteryAccountingModel} from "./utils/LotteryAccountingModel.sol";

contract SwapLotteryHookAccountingTest is LotteryTestBase {
    LotteryAccountingModel internal model;

    function setUp() public override {
        super.setUp();
        launch();
        model = new LotteryAccountingModel(manager, swapRouter, hook, key, [alice, bob, carol]);

        // Seed the invariant with empty rollover, expired rollover, a win and a payout.
        // This makes conservation non-vacuous even if subsequent random actions never draw.
        model.buy(0, 0.001 ether - 1, true);
        model.advance(3600);
        model.seal(0);
        model.resolve(0, 0, keccak256("empty"));
        model.cycle(0, 0.001 ether, true, keccak256("expired"));
        model.cycle(1, 0.01 ether, false, keccak256("winner"));
        model.claim(1);
        model.buy(2, 0.001 ether, true);
        model.assertAccounting();

        targetContract(address(model));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LotteryAccountingModel.buy.selector;
        selectors[1] = LotteryAccountingModel.advance.selector;
        selectors[2] = LotteryAccountingModel.seal.selector;
        selectors[3] = LotteryAccountingModel.resolve.selector;
        selectors[4] = LotteryAccountingModel.claim.selector;
        selectors[5] = LotteryAccountingModel.cycle.selector;
        selectors[6] = LotteryAccountingModel.buy.selector;
        targetSelector(FuzzSelector({addr: address(model), selectors: selectors}));
    }

    function invariant_independentPotsRolloversAndWinningsEqualClaims() public view {
        model.assertAccounting();
        assertGe(model.rollovers(), 2, "rollover path exercised");
        assertGe(model.draws(), 1, "winner path exercised");
        assertGt(model.paid(), 0, "payout path exercised");
    }

    function testFuzz_chainedRolloversAndAccumulatedWinnings(uint256 amount, uint256 cycles, bytes32 entropy) public {
        cycles = bound(cycles, 1, 8);
        for (uint256 i; i < cycles; i++) {
            model.cycle(i, amount, true, keccak256(abi.encode(entropy, i)));
            model.assertAccounting();
        }
        // Both wins accrue to Alice; one claim must burn exactly the combined liability.
        model.cycle(0, amount, false, entropy);
        model.assertAccounting();
        model.cycle(0, amount, false, keccak256(abi.encode(entropy)));
        model.assertAccounting();
        model.claim(0);
        model.assertAccounting();
        model.claim(0); // an expected NothingToClaim revert, checked without hiding other errors
        model.assertAccounting();
    }
}
