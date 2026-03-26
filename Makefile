-include .env

LOCAL_RPC  = http://127.0.0.1:8545
DEPLOY_SCRIPT = script/DeployV2.s.sol:DeployV2

# Clean and Build
build:
	forge build

deploy-local:
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(LOCAL_RPC) \
		--private-key $(LOCAL_PRIVATE_KEY) \
		--broadcast \
		-vvvv

deploy-sepolia:
	forge script $(DEPLOY_SCRIPT) \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvvv