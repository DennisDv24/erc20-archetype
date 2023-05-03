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
error WrongMerkleRoot();
error WrongRewardsWeight();
error WrongExtraRewardsWeight();
error WrongNftContract();
error LockedForever();

type Bps is uint256;

struct Config {
	bool mintLocked;
	bool ownerMintLocked;
	uint256 maxSupply;
	bool maxSupplyLocked;
	bool weightedAuctionRewardsLocked;
	bool auctionRewardsLocked;
	bool nftHoldsRewardsLocked;
}

/**
 * @dev An WeightedRewardedAuction will distribute weighted rewards based on a
 * variable in the `weightedVariableRoot`. For example, if `weightedVariableRoot`
 * defined an mapping between `address bidder` and `uint256 derivsHeld`, and if `sh`
 * were the shares for `bidder`, then the rewards will be calculated as:
 * 
 *    sh * baseRewardWeight * (1 + extraRewardWeight * derivsHeld) 
 *
 * Note that the weights are codified as Bps, so some conversions are required. 
 * @param acutionContract Should implement the IHoldsShares interface so
 * `getAndClaimShares` can be called when implementing rewards claiming logic.
 * @param hasExtraRewards Will determine if the rewards are weighted based on
 * `weightedVariableRoot`. If thats the case, the contract owner should call
 * `configureWeightedAuctionRewards` instead of `configureAuctionRewards`.
 */
struct WeightedRewardedAuctionConfig {
	bool isEnabled;
	bool hasExtraRewards;
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
	WeightedRewardedAuctionConfig public auctionRewardsConfig;
	RewardedNftHoldingConfig public nftHoldsRewardConfig;
	
	// TODO add cute UTFs and asciis to the code and test them on etherscan (Critical).
	/*****************************************************\
	|* Contract Initialization And Configuration Methods *|
	\*****************************************************/
	constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

	function setMaxSupply(uint256 _maxSupply) public onlyOwner {
		config.maxSupply = _maxSupply;
	}
	
	function configureWeightedAuctionRewards(
		uint256 _rewardWeight,
		uint256 _extraRewardWeight,
		bytes32 _weightedVariableRoot,
		address _auctionContract
	) public onlyOwner {
		if (config.weightedAuctionRewardsLocked) revert LockedForever();
		if (_extraRewardWeight == 0) revert WrongExtraRewardsWeight();
		if (_weightedVariableRoot == bytes32(0)) revert WrongMerkleRoot();

		configureAuctionRewards(_rewardWeight, _auctionContract);
		auctionRewardsConfig.hasExtraRewards = true;
		auctionRewardsConfig.extraRewardWeight = _extraRewardWeight;
		auctionRewardsConfig.weightedVariableRoot = _weightedVariableRoot; 
	}

	function configureAuctionRewards(
		uint256 _rewardWeight, address _auctionContract
	) public onlyOwner {
		if (config.auctionRewardsLocked) revert LockedForever();
		if (_rewardWeight == 0) revert WrongRewardsWeight();
		if (!IHoldsShares(_auctionContract).getIsSharesUpdater(address(this))) 
			revert AuctionContractNotConfigured();

		auctionRewardsConfig.isEnabled = true;
		auctionRewardsConfig.hasExtraRewards = false;
		auctionRewardsConfig.baseRewardWeight = _rewardWeight;
		auctionRewardsConfig.auctionContract = _auctionContract;
	}

	function configureNftHoldingRewards(
		uint256 _rewardWeightPerDay, address _nftContract
	) public onlyOwner {
		if (config.nftHoldsRewardsLocked) revert LockedForever();
		if (_rewardWeightPerDay == 0) revert WrongRewardsWeight();
		if (_nftContract == address(0)) revert WrongNftContract();

		nftHoldsRewardConfig.isEnabled = true;
		nftHoldsRewardConfig.rewardWeightPerDay = _rewardWeightPerDay;
		nftHoldsRewardConfig.rewardsDistributionStarted = block.timestamp;
		nftHoldsRewardConfig.nftContract = _nftContract;
	}
	
	/********************\
	|* Minting  Methods *|
	\********************/
	function _mint(address account, uint256 amount) internal virtual override {
		if (config.mintLocked) revert MintLocked();
		super._mint(account, amount);
	}

	function ownerMint(address account, uint256 amount) public onlyOwner() {
		if (config.ownerMintLocked) revert OwnerMintLocked();
	}
	
	/****************************\
	|* Rewards claiming methods *|
	\****************************/
	function claimAuctionRewards() public {
		if (auctionRewardsConfig.hasExtraRewards)
			revert WrongRewardsClaim();

		bytes32[] memory proof = new bytes32[](1);
		claimWeightedAuctionRewards(proof, 0);
	}

	function claimWeightedAuctionRewards(
		bytes32[] memory proof, uint96 timesConditonMet
	) public {
		if (supplyLeft() == 0) revert MaxSupplyExceded();

		if (!auctionRewardsConfig.isEnabled)
			revert AuctionRewardsNotSet();

		IHoldsShares auction = IHoldsShares(auctionRewardsConfig.auctionContract);
		uint256 shares = auction.getAndClearSharesFor(msg.sender);
		
		if (!verifyCondition(proof, msg.sender, timesConditonMet))
			timesConditonMet = 0;
		
		_mint(
			msg.sender,
			min(getRewardsFor(timesConditonMet, shares), supplyLeft())
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
		RewardedNftHoldingConfig storage conf = nftHoldsRewardConfig;

		if (!conf.isEnabled) revert AuctionRewardsNotSet();
		if (supplyLeft() == 0) revert MaxSupplyExceded();

		uint256 amountToClaim;

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
		
		amountToClaim = min(amountToClaim, supplyLeft());

		_mint(msg.sender, amountToClaim);
		
	}
	
	/********************\
	|* Helper functions *|
	\********************/
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

	function supplyLeft() public view returns (uint256) {
		return totalSupply() > config.maxSupply ? 
			0 : config.maxSupply - totalSupply();
	}

	/***************************************\
	|* Logic Locking and Disabling Methods *|
	\***************************************/
	function disableAuctionRewards() public onlyOwner {
		auctionRewardsConfig.isEnabled = false;
	}

	function disableWeightedAuctionRewards() public onlyOwner {
		auctionRewardsConfig.isEnabled = false;
		// For security reasons we make the owner to configure the auction
		// rewards again, if he wanted non-weighted auction rewards
		auctionRewardsConfig.hasExtraRewards = false;
	}

	function disableNftHoldingRewards() public onlyOwner {
		nftHoldsRewardConfig.isEnabled = false;
	}
	
	function lockMaxSupplyForever() public onlyOwner {
		config.maxSupplyLocked = true;
	}

	function lockAllMintsForever() public onlyOwner {
		config.mintLocked = true;
	}

	function lockOwnerMintsForever() public onlyOwner {
		config.ownerMintLocked = true;
	}

	function lockWeightedAuctionRewardsForever() public onlyOwner {
		config.weightedAuctionRewardsLocked = true;
		// For security reasons we make the owner to configure the auction
		// rewards again, if he wanted non-weighted auction rewards
		auctionRewardsConfig.isEnabled = false;
		auctionRewardsConfig.hasExtraRewards = false;
	}

	function lockAuctionRewardsForever() public onlyOwner {
		config.auctionRewardsLocked  = true;
		auctionRewardsConfig.isEnabled = false;
	}

	function lockNftHoldsRewardsForever() public onlyOwner {
		config.nftHoldsRewardsLocked = true;
		nftHoldsRewardConfig.isEnabled = false;
	}


}
