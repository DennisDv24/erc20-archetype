// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@scatter-auction/contracts/IHoldsShares.sol";
import "solady/src/utils/MerkleProofLib.sol";


error MintLocked();
error OwnerMintLocked();
error NotAuctionRewardableToken();
error AuctionRewardsNotSet();
error AuctionContractNotConfigured();
error WrongRewardsClaim();
error OwnershipError();
error MaxSupplyExceded();

type Bps is uint256;

// TODO refactor TODO REFACTOR WTFS THIS STRUCT BRO
struct Config {
	address auctionContract; // optional address if contract supports auctions.
}

struct Options {
	bool mintLocked;
	bool ownerMintLocked;
}

/**
 * @dev An WeightedRewardedAuction will distribute weighted rewards
 * based on a variable in the `weightedVariableRoot`. For example, if
 * `weightedVariableRoot` defined an mapping between `address bidder`
 * and `uint256 derivsHeld`, and if `sh` were the shares for `bidder`,
 * then the rewards will be calculated as:
 * 
 *    sh * baseRewardWeight * (1 + extraRewardWeight * derivsHeld) 
 *
 * Note that the weights are codified as Bps, so some conversions
 * are required. To have normal rewarded auctions based on
 * `baseRewardWeight` simpply set the `weightedVariableRoot` to 0. In
 * any other case, `isEnabled` should be false.
 * @param acutionContract should implement the IHoldsShares interface
 * so `getAndClaimShares` can be called when implementing rewards
 * claiming logic.
 */
struct WeightedRewardedAuctionConfig {
	bool isEnabled;
	uint256 baseRewardWeight; // Bps
	uint256 extraRewardWeight; // Bps
	bytes32 weightedVariableRoot;
	address auctionContract;
}

/**
 * @dev Rewards will be distributed based on `nftContract` holds.
 * @param rewardsDistributionStarted Will return a timestamp when the
 * rewards were configured so `lastTimeCreated` can be computed.
 */
struct RewardedNftHoldingConfig {
	bool isEnabled;
	uint256 rewardWeightPerDay; // Bps
	uint256 rewardsDistributionStarted;
	mapping (uint256 => uint256) lastTimeClaimed;
	address nftContract;
}


contract Archetype20 is Ownable, ERC20 {
	
	Config public config;
	Options public options;

	WeightedRewardedAuctionConfig public auctionRewardsConfig;
	RewardedNftHoldingConfig public nftHoldsRewardConfig;
	
	uint256 MAX_SUPPLY = 10; // TODO refactor :)
	
	// TODO add cute UTFs and asciis to the code and test them on etherscan (Critical).
	// TODO add contract configuration methods.
	/* Contract Initialization Methods */
	constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
	
	/* Minting  Methods */
	function _mint(address account, uint256 amount) internal virtual override {
		if (options.mintLocked) revert MintLocked();
		super._mint(account, amount);
	}

	function ownerMint(address account, uint256 amount) public onlyOwner() {
		if (options.ownerMintLocked) revert OwnerMintLocked();
	}
	
	/* Rewards claiming methods */
	function claimAuctionRewards() public {
		if (auctionRewardsConfig.weightedVariableRoot != bytes32(0))
			revert WrongRewardsClaim();

		bytes32[] memory proof = new bytes32[](1);
		claimWeightedAuctionRewards(proof, 0);
	}

	function claimWeightedAuctionRewards(
		bytes32[] memory proof, uint96 timesConditonMet
	) public {
		if (totalSupply() >= MAX_SUPPLY) revert MaxSupplyExceded();

		if (config.auctionContract == address(0) || !auctionRewardsConfig.isEnabled)
			revert AuctionRewardsNotSet();

		IHoldsShares auction = IHoldsShares(config.auctionContract);

		if (!auction.getIsSharesUpdater(address(this))) 
			revert AuctionContractNotConfigured();

		uint256 shares = auction.getAndClearSharesFor(msg.sender);
		
		if (!verifyCondition(proof, msg.sender, timesConditonMet))
			timesConditonMet = 0;
		
		_mint(
			msg.sender,
			min(getRewardsFor(timesConditonMet, shares), MAX_SUPPLY - totalSupply())
		);
	}

	function getRewardsFor(
		uint256 timesConditonMet, uint256 shares
	) public view returns (uint256) {

		uint256 baseAmount = shares * auctionRewardsConfig.baseRewardWeight / 10000;
		return baseAmount * (
			1 + timesConditonMet * auctionRewardsConfig.extraRewardWeight / 10000
		);
	}

	// TODO hard test this, its dangerous code
	/**
	 * @param ids Array with all the ids to claim the rewards for.
	 */
	function claimRewardsForNftsHeld(
		uint16[] calldata ids 
	) public {
		if (totalSupply() >= MAX_SUPPLY) revert MaxSupplyExceded();

		uint256 amountToClaim;
		RewardedNftHoldingConfig storage conf = nftHoldsRewardConfig;

		for (uint16 i; i < ids.length; ) {
			
			if (IERC721(conf.nftContract).ownerOf(ids[i]) != msg.sender)
				revert OwnershipError();

			uint256 timePassed = block.timestamp - max(
				conf.rewardsDistributionStarted, conf.lastTimeClaimed[ids[i]]
			);

			amountToClaim += timePassed * conf.rewardWeightPerDay 
				/ 1 days;

			conf.lastTimeClaimed[ids[i]] = block.timestamp;
		}
		
		amountToClaim = min(amountToClaim, MAX_SUPPLY - totalSupply());

		_mint(msg.sender, amountToClaim);
		
	}
	
	/* Helper functions */
	function max(uint256 a, uint256 b) public pure returns (uint256) {
		return a >= b ? a : b;
	}

	function min(uint256 a, uint256 b) public pure returns (uint256) {
		return a >= b ? b : a;
	}

	function verifyCondition(
		bytes32[] memory proof, address bidder, uint96 timesConditonMet
	) public view returns (bool) {
		if (auctionRewardsConfig.weightedVariableRoot == bytes32(0)) return false;
		return MerkleProofLib.verify(
			proof,
			auctionRewardsConfig.weightedVariableRoot,
			keccak256(abi.encodePacked(bidder, timesConditonMet))
		);
	}

}
