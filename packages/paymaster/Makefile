.PHONY: build test fmt clean deploy dry-run

build:
	forge build

test:
	forge test -vv

fmt:
	forge fmt

clean:
	forge clean

dry-run:
	forge script script/DeployPaymaster.s.sol:DeployPaymaster --rpc-url $$UNICHAIN_RPC_PRIMARY

deploy:
	forge script script/DeployPaymaster.s.sol:DeployPaymaster \
		--rpc-url $$UNICHAIN_RPC_PRIMARY \
		--broadcast \
		--verify \
		--verifier etherscan \
		--verifier-url $$ETHERSCAN_V2_URL \
		--etherscan-api-key $$ETHERSCAN_API_KEY
