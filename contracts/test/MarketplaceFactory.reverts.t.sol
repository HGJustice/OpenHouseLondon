// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";
import "../src/MarketplaceFactory.sol";

contract MarketplaceTestReverts is BaseTest {
    function test_insufficientFundsFail() external {
        vm.expectRevert(MarketplaceFactory.InsufficientSetupFee.selector);
        _createDefaultMarket(user1, 0.03 ether);
    }

    function test_invalidTitleFail() external {
        vm.prank(user1);
        vm.expectRevert(MarketplaceFactory.TitleNotLongEnough.selector);
        marketplaceContract.createMarket{value: 0.05 ether}("fjfjf", 4223233);
    }

    // function test_invalidDeadlineFail() external {
    //     vm.expectRevert(MarketplaceFactory.DeadlineNotLongEnough.selector);
    //    _createDefaultMarket(user1, 0.05 ether);
    // }

    function test_withdrawProtocolFeesFail() external {
        _createDefaultMarket(user1, 0.05 ether);
        vm.prank(user1);
        vm.expectRevert(MarketplaceFactory.OnlyOwnerAccess.selector);
        marketplaceContract.withdrawFees();
    }
}
