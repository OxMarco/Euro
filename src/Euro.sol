// SPDX-License-Identifier: GLP3
pragma solidity =0.8.17;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { console2 } from "forge-std/console2.sol";

interface IStrategy {
    function canBeHarvested() external view returns (bool);

    function harvest() external returns (int256);
}

// PLEASE READ BEFORE CHANGING ANY ACCOUNTING OR MATH
// Anytime there is division, there is a risk of numerical instability from rounding errors. In
// order to minimize this risk, we adhere to the following guidelines:
// 1) The conversion rate adopted is the number of gons that equals 1 token.
//    The inverse rate must not be used--TOTAL_GONS is always the numerator and _totalSupply is
//    always the denominator. (i.e. If you want to convert gons to tokens instead of
//    multiplying by the inverse rate, you should divide by the normal rate)
// 2) Gon balances converted into Euros are always rounded down (truncated).
//
// We make the following guarantees:
// - If address 'A' transfers x Euros to address 'B'. A's resulting external balance will
//   be decreased by precisely x Euros, and B's external balance will be precisely
//   increased by x Euros.
//
// We do not guarantee that the sum of all balances equals the result of calling totalSupply().
// This is because, for any conversion function 'f()' that has non-zero rounding error,
// f(x0) + f(x1) + ... + f(xn) is not always equal to f(x0 + x1 + ... xn).

contract Euro is ERC20, Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant INITIAL_SUPPLY = 50 * 10**6 * 10**9;

    // TOTAL_GONS is a multiple of INITIAL_SUPPLY so that _gonsPerToken is an integer.
    // Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_SUPPLY);

    // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
    uint256 private constant MAX_SUPPLY = type(uint128).max; // (2^128) - 1

    uint256 private _totalSupply;
    uint256 private _gonsPerToken;
    mapping(address => uint256) private _gonBalances;

    mapping(address => uint256) public basket;
    address[] public strategies;

    event BasketUpdate(address indexed token);
    event StrategiesUpdate(address indexed strategy);
    event LogRebase(uint256 totalSupply);

    error TokenNotAccepted();
    error InsufficientBalance();

    constructor() ERC20("Euro", "EURO") {
        _totalSupply = INITIAL_SUPPLY;
        _gonBalances[msg.sender] = TOTAL_GONS;
        _gonsPerToken = TOTAL_GONS / _totalSupply;
        emit Transfer(address(0), owner(), _totalSupply);
    }

    /**
     * @dev Exclude self-send, burns and transfers to non EOA
     */
    modifier validRecipient(address to) {
        assert(to != address(0));
        assert(to != address(this));
        assert(to.code.length == 0);
        _;
    }

    modifier allowed(address token) {
        if (basket[token] == 0) revert TokenNotAccepted();
        _;
    }

    function addToken(address token) external onlyOwner {
        basket[token] = 1;

        emit BasketUpdate(token);
    }

    function addStrategy(address strategy) external onlyOwner {
        strategies.push(strategy);

        emit StrategiesUpdate(strategy);
    }

    function mint(address tokenIn, uint256 amount) external allowed(tokenIn) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);

        uint256 toBeMinted = _computeRatio(tokenIn) * amount;
        _mint(msg.sender, toBeMinted);
    }

    function burn(address tokenOut, uint256 amount) external allowed(tokenOut) {
        uint256 toBeTransferred = amount / _computeRatio(tokenOut);

        IERC20 token = IERC20(tokenOut);
        if (token.balanceOf(address(this)) < toBeTransferred) revert InsufficientBalance();

        _burn(msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function check() external view returns (bool, bytes memory) {
        uint8[] memory toHarvest = new uint8[](strategies.length);

        uint8 length = uint8(strategies.length);
        uint8 counter = 0;
        for (uint8 i = 0; i < length; i++) {
            if (IStrategy(strategies[i]).canBeHarvested()) {
                toHarvest[counter] = i;
                counter++;
            }
        }

        return (counter > 0 ? true : false, abi.encode(toHarvest));
    }

    function exec(uint8[] calldata indexes) external {
        int256 results = 0;

        uint8 length = uint8(indexes.length);
        for (uint8 i = 0; i < length; i++) {
            results += IStrategy(strategies[indexes[i]]).harvest();
        }

        _rebase(results);
    }

    function _computeRatio(address token) internal view returns (uint256) {
        return 1;
    }

    /**
     * @dev Notifies the contract about a new rebase cycle.
     * @param supplyDelta The number of tokens to add into or remove from circulation.
     * @return The total number of tokens after the supply adjustment.
     */
    function _rebase(int256 supplyDelta) public returns (uint256) {
        if (supplyDelta == 0) {
            emit LogRebase(_totalSupply);
            return _totalSupply;
        }

        if (supplyDelta < 0) {
            _totalSupply = _totalSupply - uint256(-supplyDelta);
        } else {
            _totalSupply = _totalSupply + uint256(supplyDelta);
        }

        if (_totalSupply > MAX_SUPPLY) {
            _totalSupply = MAX_SUPPLY;
        }

        _gonsPerToken = TOTAL_GONS / _totalSupply;

        // From this point forward, _gonsPerToken is taken as the source of truth.
        // We recalculate a new _totalSupply to be in agreement with the _gonsPerToken
        // conversion rate.
        // This means our applied supplyDelta can deviate from the requested supplyDelta,
        // but this deviation is guaranteed to be < (_totalSupply^2)/(TOTAL_GONS - _totalSupply).
        //
        // In the case of _totalSupply <= MAX_UINT128 (our current supply cap), this
        // deviation is guaranteed to be < 1, so we can omit this step. If the supply cap is
        // ever increased, it must be re-included.
        // _totalSupply = TOTAL_GONS.div(_gonsPerToken)

        emit LogRebase(_totalSupply);
        return _totalSupply;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address who) public view override returns (uint256) {
        return _gonBalances[who] / _gonsPerToken;
    }

    /**
     * @param who The address to query.
     * @return The gon balance of the specified address.
     */
    function scaledBalanceOf(address who) external view returns (uint256) {
        return _gonBalances[who];
    }

    /**
     * @return the total number of gons.
     */
    function scaledTotalSupply() external pure returns (uint256) {
        return TOTAL_GONS;
    }

    function transfer(address to, uint256 value) public override validRecipient(to) returns (bool) {
        uint256 gonValue = value * _gonsPerToken;
        _gonBalances[msg.sender] = _gonBalances[msg.sender] - gonValue;
        _gonBalances[to] = _gonBalances[to] + gonValue;

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override validRecipient(to) returns (bool) {
        assert(from != address(0));

        _spendAllowance(from, msg.sender, value);

        uint256 gonValue = value * _gonsPerToken;
        _gonBalances[from] = _gonBalances[from] - gonValue;
        _gonBalances[to] = _gonBalances[to] + gonValue;

        emit Transfer(from, to, value);
        return true;
    }
}
