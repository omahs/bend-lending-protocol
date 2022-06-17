// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.4;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC721HolderUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";

import {Constants} from "../libraries/helpers/Constants.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {ILendPool} from "../interfaces/ILendPool.sol";
import {ILendPoolLoan} from "../interfaces/ILendPoolLoan.sol";
import {ILendPoolAddressesProvider} from "../interfaces/ILendPoolAddressesProvider.sol";
import {IPunks} from "../interfaces/IPunks.sol";
import {IWrappedPunks} from "../interfaces/IWrappedPunks.sol";
import {IPunkGateway} from "../interfaces/IPunkGateway.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {IWETHGateway} from "../interfaces/IWETHGateway.sol";
import {IWETH} from "../interfaces/IWETH.sol";

import {EmergencyTokenRecoveryUpgradeable} from "./EmergencyTokenRecoveryUpgradeable.sol";

contract PunkGateway is IPunkGateway, ERC721HolderUpgradeable, EmergencyTokenRecoveryUpgradeable {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  ILendPoolAddressesProvider internal _addressProvider;
  IWETHGateway internal _wethGateway; // Deprecated, use _getWETHGateway instead

  IPunks public punks;
  IWrappedPunks public wrappedPunks;
  address public proxy;

  mapping(address => bool) internal _callerWhitelists;

  uint256 private constant _NOT_ENTERED = 0;
  uint256 private constant _ENTERED = 1;
  uint256 private _status;

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   * Calling a `nonReentrant` function from another `nonReentrant`
   * function is not supported. It is possible to prevent this from happening
   * by making the `nonReentrant` function external, and making it call a
   * `private` function that does the actual work.
   */
  modifier nonReentrant() {
    // On the first call to nonReentrant, _notEntered will be true
    require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

    // Any calls to nonReentrant after this point will fail
    _status = _ENTERED;

    _;

    // By storing the original value once again, a refund is triggered (see
    // https://eips.ethereum.org/EIPS/eip-2200)
    _status = _NOT_ENTERED;
  }

  function initialize(
    address addressProvider,
    address wethGateway,
    address _punks,
    address _wrappedPunks
  ) public initializer {
    __ERC721Holder_init();
    __EmergencyTokenRecovery_init();

    _addressProvider = ILendPoolAddressesProvider(addressProvider);
    _wethGateway = IWETHGateway(wethGateway);

    punks = IPunks(_punks);
    wrappedPunks = IWrappedPunks(_wrappedPunks);
    wrappedPunks.registerProxy();
    proxy = wrappedPunks.proxyInfo(address(this));

    IERC721Upgradeable(address(wrappedPunks)).setApprovalForAll(address(_getLendPool()), true);
    IERC721Upgradeable(address(wrappedPunks)).setApprovalForAll(address(_wethGateway), true);
  }

  function _getLendPool() internal view returns (ILendPool) {
    return ILendPool(_addressProvider.getLendPool());
  }

  function _getLendPoolLoan() internal view returns (ILendPoolLoan) {
    return ILendPoolLoan(_addressProvider.getLendPoolLoan());
  }

  function _getWETHGateway() internal view returns (IWETHGateway) {
    return IWETHGateway(_addressProvider.getAddress(Constants.AID_WETH_GATEWAY));
  }

  function _getWETH() internal view returns (IWETH) {
    return IWETH(_getWETHGateway().getWETHAddress());
  }

  function authorizeLendPoolERC20(address[] calldata tokens) external nonReentrant onlyOwner {
    for (uint256 i = 0; i < tokens.length; i++) {
      IERC20Upgradeable(tokens[i]).approve(address(_getLendPool()), type(uint256).max);
    }
  }

  function authorizeCallerWhitelist(address[] calldata callers, bool flag) external nonReentrant onlyOwner {
    for (uint256 i = 0; i < callers.length; i++) {
      _callerWhitelists[callers[i]] = flag;
    }
  }

  function isCallerInWhitelist(address caller) external view returns (bool) {
    return _callerWhitelists[caller];
  }

  function _checkValidCallerAndOnBehalfOf(address onBehalfOf) internal view {
    require(
      (onBehalfOf == _msgSender()) || (_callerWhitelists[_msgSender()] == true),
      Errors.CALLER_NOT_ONBEHALFOF_OR_IN_WHITELIST
    );
  }

  function _depositPunk(uint256 punkIndex) internal {
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    if (loanId != 0) {
      return;
    }

    address owner = punks.punkIndexToAddress(punkIndex);
    require(owner == _msgSender(), "PunkGateway: not owner of punkIndex");

    punks.buyPunk(punkIndex);
    punks.transferPunk(proxy, punkIndex);

    wrappedPunks.mint(punkIndex);
  }

  function borrow(
    address reserveAsset,
    uint256 amount,
    uint256 punkIndex,
    address onBehalfOf,
    uint16 referralCode
  ) external override nonReentrant {
    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    ILendPool cachedPool = _getLendPool();

    _depositPunk(punkIndex);

    cachedPool.borrow(reserveAsset, amount, address(wrappedPunks), punkIndex, onBehalfOf, referralCode);
    IERC20Upgradeable(reserveAsset).transfer(onBehalfOf, amount);
  }

  function batchBorrow(
    address[] calldata reserveAssets,
    uint256[] calldata amounts,
    uint256[] calldata punkIndexs,
    address onBehalfOf,
    uint16 referralCode
  ) external override nonReentrant {
    require(punkIndexs.length == reserveAssets.length, "inconsistent reserveAssets length");
    require(punkIndexs.length == amounts.length, "inconsistent amounts length");

    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    ILendPool cachedPool = _getLendPool();

    for (uint256 i = 0; i < punkIndexs.length; i++) {
      _depositPunk(punkIndexs[i]);

      cachedPool.borrow(reserveAssets[i], amounts[i], address(wrappedPunks), punkIndexs[i], onBehalfOf, referralCode);

      IERC20Upgradeable(reserveAssets[i]).transfer(onBehalfOf, amounts[i]);
    }
  }

  function _withdrawPunk(uint256 punkIndex, address onBehalfOf) internal {
    address owner = wrappedPunks.ownerOf(punkIndex);
    require(owner == _msgSender(), "PunkGateway: caller is not owner");
    require(owner == onBehalfOf, "PunkGateway: onBehalfOf is not owner");

    wrappedPunks.safeTransferFrom(onBehalfOf, address(this), punkIndex);
    wrappedPunks.burn(punkIndex);
    punks.transferPunk(onBehalfOf, punkIndex);
  }

  function repay(uint256 punkIndex, uint256 amount) external override nonReentrant returns (uint256, bool) {
    return _repay(punkIndex, amount);
  }

  function batchRepay(uint256[] calldata punkIndexs, uint256[] calldata amounts)
    external
    override
    nonReentrant
    returns (uint256[] memory, bool[] memory)
  {
    require(punkIndexs.length == amounts.length, "inconsistent amounts length");

    uint256[] memory repayAmounts = new uint256[](punkIndexs.length);
    bool[] memory repayAlls = new bool[](punkIndexs.length);

    for (uint256 i = 0; i < punkIndexs.length; i++) {
      (repayAmounts[i], repayAlls[i]) = _repay(punkIndexs[i], amounts[i]);
    }

    return (repayAmounts, repayAlls);
  }

  function _repay(uint256 punkIndex, uint256 amount) internal returns (uint256, bool) {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");
    (, , address reserve, ) = cachedPoolLoan.getLoanCollateralAndReserve(loanId);
    (, uint256 debt) = cachedPoolLoan.getLoanReserveBorrowAmount(loanId);
    address borrower = cachedPoolLoan.borrowerOf(loanId);

    if (amount > debt) {
      amount = debt;
    }

    IERC20Upgradeable(reserve).transferFrom(msg.sender, address(this), amount);

    (uint256 paybackAmount, bool burn) = cachedPool.repay(address(wrappedPunks), punkIndex, amount);

    if (burn) {
      require(borrower == _msgSender(), "PunkGateway: caller is not borrower");
      _withdrawPunk(punkIndex, borrower);
    }

    return (paybackAmount, burn);
  }

  function auction(
    uint256 punkIndex,
    uint256 bidPrice,
    address onBehalfOf
  ) external override nonReentrant {
    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    (, , address reserve, ) = cachedPoolLoan.getLoanCollateralAndReserve(loanId);

    IERC20Upgradeable(reserve).transferFrom(msg.sender, address(this), bidPrice);

    cachedPool.auction(address(wrappedPunks), punkIndex, bidPrice, onBehalfOf);
  }

  function redeem(
    uint256 punkIndex,
    uint256 amount,
    uint256 bidFine
  ) external override nonReentrant returns (uint256) {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    DataTypes.LoanData memory loan = cachedPoolLoan.getLoan(loanId);

    IERC20Upgradeable(loan.reserveAsset).transferFrom(msg.sender, address(this), (amount + bidFine));

    uint256 paybackAmount = cachedPool.redeem(address(wrappedPunks), punkIndex, amount, bidFine);

    if ((amount + bidFine) > paybackAmount) {
      IERC20Upgradeable(loan.reserveAsset).safeTransfer(msg.sender, ((amount + bidFine) - paybackAmount));
    }

    return paybackAmount;
  }

  function liquidate(uint256 punkIndex, uint256 amount) external override nonReentrant returns (uint256) {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    DataTypes.LoanData memory loan = cachedPoolLoan.getLoan(loanId);
    require(loan.bidderAddress == _msgSender(), "PunkGateway: caller is not bidder");

    if (amount > 0) {
      IERC20Upgradeable(loan.reserveAsset).transferFrom(msg.sender, address(this), amount);
    }

    uint256 extraRetAmount = cachedPool.liquidate(address(wrappedPunks), punkIndex, amount);

    _withdrawPunk(punkIndex, loan.bidderAddress);

    if (amount > extraRetAmount) {
      IERC20Upgradeable(loan.reserveAsset).safeTransfer(msg.sender, (amount - extraRetAmount));
    }

    return (extraRetAmount);
  }

  function borrowETH(
    uint256 amount,
    uint256 punkIndex,
    address onBehalfOf,
    uint16 referralCode
  ) external override nonReentrant {
    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    _borrowETH(amount, punkIndex, onBehalfOf, referralCode);
  }

  function batchBorrowETH(
    uint256[] calldata amounts,
    uint256[] calldata punkIndexs,
    address onBehalfOf,
    uint16 referralCode
  ) external override nonReentrant {
    require(punkIndexs.length == amounts.length, "inconsistent amounts length");

    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    for (uint256 i = 0; i < punkIndexs.length; i++) {
      _borrowETH(amounts[i], punkIndexs[i], onBehalfOf, referralCode);
    }
  }

  function _borrowETH(
    uint256 amount,
    uint256 punkIndex,
    address onBehalfOf,
    uint16 referralCode
  ) internal {
    ILendPool cachedPool = _getLendPool();
    IWETH weth = _getWETH();

    _depositPunk(punkIndex);

    cachedPool.borrow(address(weth), amount, address(wrappedPunks), punkIndex, onBehalfOf, referralCode);

    weth.withdraw(amount);
    _safeTransferETH(onBehalfOf, amount);
  }

  function repayETH(uint256 punkIndex, uint256 amount) external payable override nonReentrant returns (uint256, bool) {
    // convert eth to weth and make sure enough weth
    uint256 wethSendAmount = _wrapAndTransferWETH(amount);

    (uint256 paybackAmount, bool burn) = _repayETH(punkIndex, amount);

    // refund remaining dust eth
    _unwrapAndRefundWETH(wethSendAmount, paybackAmount);

    return (paybackAmount, burn);
  }

  function batchRepayETH(uint256[] calldata punkIndexs, uint256[] calldata amounts)
    external
    payable
    override
    nonReentrant
    returns (uint256[] memory, bool[] memory)
  {
    require(punkIndexs.length == amounts.length, "inconsistent amounts length");

    // convert eth to weth and make sure enough weth
    uint256 totalRepayAmount = 0;
    for (uint256 i = 0; i < punkIndexs.length; i++) {
      totalRepayAmount += amounts[i];
    }
    uint256 wethSendAmount = _wrapAndTransferWETH(totalRepayAmount);

    // recording all repaid amounts
    uint256[] memory repayAmounts = new uint256[](punkIndexs.length);
    bool[] memory repayAlls = new bool[](punkIndexs.length);
    uint256 allRepayAmount = 0;

    for (uint256 i = 0; i < punkIndexs.length; i++) {
      (repayAmounts[i], repayAlls[i]) = _repayETH(punkIndexs[i], amounts[i]);
      allRepayAmount += repayAmounts[i];
    }

    // refund remaining dust eth
    _unwrapAndRefundWETH(wethSendAmount, allRepayAmount);

    return (repayAmounts, repayAlls);
  }

  function _repayETH(uint256 punkIndex, uint256 amount) internal returns (uint256, bool) {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    address borrower = cachedPoolLoan.borrowerOf(loanId);
    require(borrower == _msgSender(), "PunkGateway: caller is not borrower");

    (uint256 paybackAmount, bool burn) = cachedPool.repay(address(wrappedPunks), punkIndex, amount);

    if (burn) {
      _withdrawPunk(punkIndex, borrower);
    }

    return (paybackAmount, burn);
  }

  function auctionETH(
    uint256 punkIndex,
    uint256 bidPrice,
    address onBehalfOf
  ) external payable override nonReentrant {
    _checkValidCallerAndOnBehalfOf(onBehalfOf);

    ILendPool cachedPool = _getLendPool();

    // convert eth to weth and make sure enough weth
    _wrapAndTransferWETH(bidPrice);

    cachedPool.auction(address(wrappedPunks), punkIndex, bidPrice, onBehalfOf);
  }

  function redeemETH(
    uint256 punkIndex,
    uint256 amount,
    uint256 bidFine
  ) external payable override nonReentrant returns (uint256) {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    // convert eth to weth and make sure enough weth
    uint256 wethSendAmount = _wrapAndTransferWETH(amount + bidFine);

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    uint256 paybackAmount = cachedPool.redeem(address(wrappedPunks), punkIndex, amount, bidFine);

    // refund remaining dust eth
    _unwrapAndRefundWETH(wethSendAmount, paybackAmount);

    return paybackAmount;
  }

  function liquidateETH(uint256 punkIndex, uint256 extraAmount)
    external
    payable
    override
    nonReentrant
    returns (uint256)
  {
    ILendPool cachedPool = _getLendPool();
    ILendPoolLoan cachedPoolLoan = _getLendPoolLoan();

    // convert eth to weth and make sure enough weth
    uint256 wethSendAmount = _wrapAndTransferWETH(extraAmount);

    uint256 loanId = cachedPoolLoan.getCollateralLoanId(address(wrappedPunks), punkIndex);
    require(loanId != 0, "PunkGateway: no loan with such punkIndex");

    DataTypes.LoanData memory loan = cachedPoolLoan.getLoan(loanId);
    require(loan.bidderAddress == _msgSender(), "PunkGateway: caller is not bidder");

    uint256 paidExtraAmount = cachedPool.liquidate(address(wrappedPunks), punkIndex, extraAmount);

    _withdrawPunk(punkIndex, loan.bidderAddress);

    // refund remaining dust eth
    _unwrapAndRefundWETH(wethSendAmount, paidExtraAmount);

    return paidExtraAmount;
  }

  /**
   * @dev transfer ETH to an address, revert if it fails.
   * @param to recipient of the transfer
   * @param value the amount to send
   */
  function _safeTransferETH(address to, uint256 value) internal {
    (bool success, ) = to.call{value: value}(new bytes(0));
    require(success, "ETH_TRANSFER_FAILED");
  }

  function _wrapAndTransferWETH(uint256 amount) internal returns (uint256) {
    IWETH weth = _getWETH();
    uint256 wethSendAmount = 0;
    if (msg.value > 0) {
      wethSendAmount = msg.value;
      weth.deposit{value: msg.value}();
    }
    if (msg.value < amount) {
      wethSendAmount = amount;
      weth.transferFrom(msg.sender, address(this), (amount - msg.value));
    }
    return wethSendAmount;
  }

  function _unwrapAndRefundWETH(uint256 sendAmount, uint256 paidAmount) internal {
    IWETH weth = _getWETH();
    if (sendAmount > paidAmount) {
      uint256 remainAmount = sendAmount - paidAmount;
      if (msg.value >= sendAmount) {
        weth.withdraw(remainAmount);
        _safeTransferETH(msg.sender, (remainAmount));
      } else {
        weth.transferFrom(address(this), msg.sender, remainAmount);
      }
    }
  }

  /**
   * @dev
   */
  receive() external payable {}

  /**
   * @dev Revert fallback calls
   */
  fallback() external payable {
    revert("Fallback not allowed");
  }
}
