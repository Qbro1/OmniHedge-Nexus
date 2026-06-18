// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract OmniHedgeNexus is FunctionsClient, AutomationCompatibleInterface, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    // ==========================================
    // CUSTOM ERRORS
    // ==========================================
    error Unauthorized();
    error InsufficientBalance();
    error UpkeepNotNeeded();
    error FunctionsError();
    error CCIPFeeFailed();
    error InvalidPriceFeed();
    error MigrationFailed();

    // ==========================================
    // STATE VARIABLES
    // ==========================================
    address public immutable owner;
    IRouterClient public immutable ccipRouter;
    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable linkToken;
    IERC20 public immutable vaultToken;

    bytes32 public donId;
    uint64 public subscriptionId;
    uint32 public fulfillGasLimit = 300000;
    string public aiRiskAnalysisSource;

    uint64 public safeDestinationChainSelector;
    address public safeDestinationVault;
    
    uint256 public totalDeposits;
    uint256 public lastRiskScore;
    uint256 public constant RISK_THRESHOLD = 80;
    
    uint256 private _flags;
    mapping(address => uint256) public userBalances;

    struct Migration {
        bytes32 messageId;
        uint256 amount;
        uint64 destinationChain;
        uint256 timestamp;
        bool completed;
    }
    mapping(bytes32 => Migration) public migrations;

    // ==========================================
    // EVENTS
    // ==========================================
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RiskAnalysisRequested(bytes32 indexed requestId);
    event RiskAnalysisReceived(bytes32 indexed requestId, uint256 riskScore);
    event EmergencyMigrationTriggered(bytes32 indexed messageId, uint256 amountMigrated);
    event MigrationCompleted(bytes32 indexed messageId);
    event EmergencyModeToggled(bool active);

    // ==========================================
    // MODIFIERS
    // ==========================================
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier notInEmergency() {
        if (isEmergencyMode()) revert Unauthorized();
        _;
    }

    // ==========================================
    // CONSTRUCTOR
    // ==========================================
    constructor(
        address _functionsRouter,
        address _ccipRouter,
        address _priceFeed,
        address _linkToken,
        address _vaultToken,
        uint64 _subId,
        bytes32 _donId,
        uint64 _destChainSelector
    ) FunctionsClient(_functionsRouter) {
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        
        owner = msg.sender;
        ccipRouter = IRouterClient(_ccipRouter);
        priceFeed = AggregatorV3Interface(_priceFeed);
        linkToken = IERC20(_linkToken);
        vaultToken = IERC20(_vaultToken);
        subscriptionId = _subId;
        donId = _donId;
        safeDestinationChainSelector = _destChainSelector;
    }

    // ==========================================
    // CORE LOGIC
    // ==========================================
    function deposit(uint256 amount) external nonReentrant notInEmergency {
        if (amount == 0) revert InsufficientBalance();
        
        vaultToken.transferFrom(msg.sender, address(this), amount);
        userBalances[msg.sender] += amount;
        totalDeposits += amount;

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant notInEmergency {
        if (userBalances[msg.sender] < amount) revert InsufficientBalance();

        userBalances[msg.sender] -= amount;
        totalDeposits -= amount;
        vaultToken.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    // ==========================================
    // CHAINLINK AUTOMATION
    // ==========================================
    function checkUpkeep(bytes calldata /* checkData */) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        try priceFeed.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256,
            uint80 
        ) {
            if (price < 1000 * 10**8 && !isEmergencyMode()) {
                upkeepNeeded = true;
                performData = abi.encode("PRICE_DROP_DETECTED");
            }
        } catch {
            upkeepNeeded = false;
        }
    }

    // ==========================================
    // FIXED: performUpkeep with proper calldata handling
    // ==========================================
    function performUpkeep(bytes calldata performData) external override {
        bytes32 triggerReason;
        
        
        assembly {
        
            triggerReason := calldataload(performData.offset)

            if iszero(triggerReason) {
                revert(0, 0)
            }
        }

        
        (, int256 currentPrice, , , ) = priceFeed.latestRoundData();
        if (currentPrice >= 1000 * 10**8) {
            revert UpkeepNotNeeded();
        }

        _requestRiskAnalysis();
    }

    // ==========================================
    // CHAINLINK FUNCTIONS
    // ==========================================
    function setAiRiskSource(string calldata source) external onlyOwner {
        aiRiskAnalysisSource = source;
    }

    function _requestRiskAnalysis() internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(aiRiskAnalysisSource);
        
        requestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            uint32(fulfillGasLimit),
            donId
        );

        emit RiskAnalysisRequested(requestId);
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (err.length > 0) revert FunctionsError();

        uint256 riskScore;
        // Assembly для работы с памятью (memory) - здесь все правильно
        assembly {
            let dataPtr := add(response, 32)
            riskScore := mload(dataPtr)
            
            if gt(riskScore, 100) {
                riskScore := 50
            }
        }

        lastRiskScore = riskScore;
        emit RiskAnalysisReceived(requestId, riskScore);

        if (riskScore >= RISK_THRESHOLD && !isEmergencyMode()) {
            _executeEmergencyCrossChainMigration();
        }
    }

    // ==========================================
    // CHAINLINK CCIP
    // ==========================================
    function setSafeVault(address _safeVault, uint64 _chainSelector) external onlyOwner {
        safeDestinationVault = _safeVault;
        if (_chainSelector != 0) {
            safeDestinationChainSelector = _chainSelector;
        }
    }

    function _executeEmergencyCrossChainMigration() internal {
        _setEmergencyMode(true);
        
        uint256 balanceToMigrate = vaultToken.balanceOf(address(this));
        if (balanceToMigrate == 0) {
            _setEmergencyMode(false);
            revert InsufficientBalance();
        }

        uint256 linkBalance = linkToken.balanceOf(address(this));
        if (linkBalance == 0) {
            _setEmergencyMode(false);
            revert CCIPFeeFailed();
        }

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(vaultToken),
            amount: balanceToMigrate
        });

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(safeDestinationVault),
            data: abi.encode("EMERGENCY_MIGRATION"),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200000})
            ),
            feeToken: address(linkToken)
        });

        uint256 fees = ccipRouter.getFee(safeDestinationChainSelector, evm2AnyMessage);
        if (linkToken.balanceOf(address(this)) < fees) {
            _setEmergencyMode(false);
            revert CCIPFeeFailed();
        }

        linkToken.approve(address(ccipRouter), fees);
        vaultToken.approve(address(ccipRouter), balanceToMigrate);

        bytes32 messageId = ccipRouter.ccipSend(safeDestinationChainSelector, evm2AnyMessage);

        migrations[messageId] = Migration({
            messageId: messageId,
            amount: balanceToMigrate,
            destinationChain: safeDestinationChainSelector,
            timestamp: block.timestamp,
            completed: false
        });

        emit EmergencyMigrationTriggered(messageId, balanceToMigrate);
    }

    // ==========================================
    // УПРАВЛЕНИЕ РЕЖИМОМ ЧС
    // ==========================================
    function isEmergencyMode() public view returns (bool) {
        return (_flags & 1) != 0;
    }

    function _setEmergencyMode(bool active) internal {
    if (active) {
        _flags |= 1;
    } else {
        _flags &= ~uint256(1);          // Явное приведение к uint256
    }
    emit EmergencyModeToggled(active);
}

    function toggleEmergencyMode() external onlyOwner {
        _setEmergencyMode(!isEmergencyMode());
    }

    // ==========================================
    // APPROVE                 L
    // ==========================================
    function confirmMigration(bytes32 messageId) external onlyOwner {
        Migration storage migration = migrations[messageId];
        if (migration.messageId == bytes32(0)) revert MigrationFailed();
        if (migration.completed) revert MigrationFailed();
        
        migration.completed = true;
        _setEmergencyMode(false);
        
        emit MigrationCompleted(messageId);
    }

    // ==========================================
    // ADMIN UTILS
    // ==========================================
    function withdrawLink() external onlyOwner {
        uint256 balance = linkToken.balanceOf(address(this));
        linkToken.transfer(owner, balance);
    }

    function recoverFunds(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}