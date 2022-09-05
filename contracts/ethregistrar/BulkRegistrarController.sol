pragma solidity >=0.8.4;

import "./BaseRegistrarImplementation.sol";
import "./StringUtils.sol";
import "../resolvers/Resolver.sol";
import "../registry/ReverseRegistrar.sol";
import "./IBulkRegistrarController.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../wrapper/INameWrapper.sol";

/**
 * @dev A registrar controller for registering and renewing names at fixed cost.
 */
contract BulkRegistrarController is Ownable, IBulkRegistrarController {
    using StringUtils for *;
    using Address for address;

    uint256 public constant MIN_REGISTRATION_DURATION = 28 days;
    bytes32 private constant ETH_NODE =
        0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    BaseRegistrarImplementation immutable base;
    IPriceOracle public immutable prices;
    uint256 public immutable minCommitmentAge;
    uint256 public immutable maxCommitmentAge;
    ReverseRegistrar public immutable reverseRegistrar;
    INameWrapper public immutable nameWrapper;

    mapping(bytes32 => uint256) public commitments;

    event NameRegistered(
        string name,
        bytes32 indexed label,
        address indexed owner,
        uint256 baseCost,
        uint256 premium,
        uint256 expires
    );
    event NameRenewed(
        string name,
        bytes32 indexed label,
        uint256 cost,
        uint256 expires
    );

    constructor(
        BaseRegistrarImplementation _base,
        IPriceOracle _prices,
        uint256 _minCommitmentAge,
        uint256 _maxCommitmentAge,
        ReverseRegistrar _reverseRegistrar,
        INameWrapper _nameWrapper
    ) {
        require(_maxCommitmentAge > _minCommitmentAge);

        base = _base;
        prices = _prices;
        minCommitmentAge = _minCommitmentAge;
        maxCommitmentAge = _maxCommitmentAge;
        reverseRegistrar = _reverseRegistrar;
        nameWrapper = _nameWrapper;
    }

    function rentPrice(string memory name, uint256 duration)
        public
        view
        override
        returns (IPriceOracle.Price memory price)
    {
        bytes32 label = keccak256(bytes(name));
        price = prices.price(name, base.nameExpires(uint256(label)), duration);
    }

    function valid(string memory name) public pure returns (bool) {
        return name.strlen() >= 3;
    }

    function available(string memory name) public view override returns (bool) {
        bytes32 label = keccak256(bytes(name));
        return valid(name) && base.available(uint256(label));
    }

    function makeCommitment(Registration memory registration) public pure override returns (bytes32) {
        bytes32 label = keccak256(bytes(registration.name));
        if (registration.data.length > 0) {
            require(
                registration.resolver != address(0),
                "BulkRegistrarController: resolver required when data supplied"
            );
        }
        return
            keccak256(
                abi.encode(
                    label,
                    registration.owner,
                    registration.duration,
                    registration.resolver,
                    registration.data,
                    registration.secret,
                    registration.reverseRecord,
                    registration.fuses,
                    registration.wrapperExpiry
                )
            );
    }

    function makeBulkCommitment(Registration[] memory registrations) public pure override returns (bytes32 commitment) {
        bytes32[] memory registrationHashes = new bytes32[](registrations.length);
        for (uint i = 0; i < registrations.length; i += 1) {
            if (bytes(registrations[i].name).length == 0) {
                registrationHashes[i] = bytes32(registrations[i].duration);
            } else {
                bytes32 hash = makeCommitment(registrations[i]);
                registrationHashes[i] = hash;
            }
        }
        commitment = keccak256(abi.encode(registrationHashes));
    }

    function commit(bytes32 commitment) public override {
        require(commitments[commitment] + maxCommitmentAge < block.timestamp);
        commitments[commitment] = block.timestamp;
    }

    function register(Registration[] calldata registrations) external payable override {
        uint256 remainingBudget = msg.value;
        bytes32[] memory registrationHashes = new bytes32[](registrations.length);
        for (uint i = 0; i < registrations.length; i += 1) {
            if (bytes(registrations[i].name).length == 0) {
                registrationHashes[i] = bytes32(registrations[i].duration);
            } else {
                bytes32 hash = makeCommitment(registrations[i]);
                registrationHashes[i] = hash;
                uint256 price = _registerName(registrations[i]);

                require(price <= remainingBudget, "Not enough ETH");
                unchecked {
                    remainingBudget -= price;
                }
            }
        }
        bytes32 commitment = keccak256(abi.encode(registrationHashes));

        _consumeCommitment(commitment);

        if (remainingBudget > 0) {
            payable(msg.sender).transfer(remainingBudget);
        }
    }

    function withdraw() public {
        payable(owner()).transfer(address(this).balance);
    }

    function supportsInterface(bytes4 interfaceID)
        external
        pure
        returns (bool)
    {
        return
            interfaceID == type(IERC165).interfaceId ||
            interfaceID == type(IBulkRegistrarController).interfaceId;
    }

    /* Internal functions */

    function _registerName(Registration calldata registration) private returns (uint256 totalPrice){
        IPriceOracle.Price memory price = rentPrice(registration.name, registration.duration);
        require(
            msg.value >= (price.base + price.premium),
            "BulkRegistrarController: Not enough ether provided"
        );

        require(available(registration.name), "BulkRegistrarController: Name is unavailable");

        require(registration.duration >= MIN_REGISTRATION_DURATION);

        uint256 expires = nameWrapper.registerAndWrapETH2LD(
            registration.name,
            registration.owner,
            registration.duration,
            registration.resolver,
            registration.fuses,
            registration.wrapperExpiry
        );

        _setRecords(registration.resolver, keccak256(bytes(registration.name)), registration.data);

        if (registration.reverseRecord) {
            _setReverseRecord(registration.name, registration.resolver, msg.sender);
        }

        emit NameRegistered(
            registration.name,
            keccak256(bytes(registration.name)),
            registration.owner,
            price.base,
            price.premium,
            expires
        );

        totalPrice = price.base + price.premium;
    }

    function _consumeCommitment(bytes32 commitment) internal {
        // Require a valid commitment (is old enough and is committed)
        require(
            commitments[commitment] + minCommitmentAge <= block.timestamp,
            "BulkRegistrarController: Commitment not valid"
        );

        // If the commitment is too old, or the name is registered, stop
        require(
            commitments[commitment] + maxCommitmentAge > block.timestamp,
            "BulkRegistrarController: Commitment expired"
        );

        delete (commitments[commitment]);
    }

    function _setRecords(
        address resolver,
        bytes32 label,
        bytes[] calldata data
    ) internal {
        // use hardcoded .eth namehash
        bytes32 nodehash = keccak256(abi.encodePacked(ETH_NODE, label));
        for (uint256 i = 0; i < data.length; i++) {
            // check first few bytes are namehash
            bytes32 txNamehash = bytes32(data[i][4:36]);
            require(
                txNamehash == nodehash,
                "BulkRegistrarController: Namehash on record do not match the name being registered"
            );
            resolver.functionCall(
                data[i],
                "BulkRegistrarController: Failed to set Record"
            );
        }
    }

    function _setReverseRecord(
        string memory name,
        address resolver,
        address owner
    ) internal {
        reverseRegistrar.setNameForAddr(
            msg.sender,
            owner,
            resolver,
            string.concat(name, ".eth")
        );
    }
}
