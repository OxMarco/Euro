// SPDX-License-Identifier: GLP3
pragma solidity =0.8.17;

import { IERC20, IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import { PRBTest } from "@prb/test/PRBTest.sol";
import { console2 } from "forge-std/console2.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { Euro } from "../src/Euro.sol";

contract EuroTest is PRBTest, StdCheats {
    Euro internal immutable euro;
    ERC20PresetMinterPauser internal immutable token1;
    ERC20PresetMinterPauser internal immutable token2;
    ERC20PresetMinterPauser internal immutable token3;
    address internal constant owner = address(uint160(uint(keccak256(abi.encodePacked("Owner")))));

    constructor() {
        token1 = new ERC20PresetMinterPauser("stable1", "STABLE1");
        token2 = new ERC20PresetMinterPauser("stable2", "STABLE2");
        token3 = new ERC20PresetMinterPauser("stable3", "STABLE3");

        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        euro = new Euro();
        euro.addToken(address(token1));
        euro.addToken(address(token2));
        euro.addToken(address(token3));
        vm.stopPrank();

        token1.approve(address(euro), type(uint256).max);
        token2.approve(address(euro), type(uint256).max);
        token3.approve(address(euro), type(uint256).max);
    }

    function setUp() public {}

    function testBasic() public {
        uint256 amount = 1e18;

        token1.mint(address(this), amount);
        euro.mint(address(token1), amount);

        console2.log("balance", euro.balanceOf(address(owner)));

        assertTrue(token1.balanceOf(address(this)) == 0);
        assertTrue(token1.balanceOf(address(euro)) == amount);
        assertTrue(euro.balanceOf(address(this)) == amount);
    }
}
