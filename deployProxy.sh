# deploy to tenderly mainnet fork network
forge script script/DeployProxy.s.sol:DeploymentProxy --broadcast --verify --rpc-url https://rpc.tenderly.co/fork/cc2b5331-1bfa-4756-84ab-e2f2f63a91d5

#forge script script/DeployProxy.s.sol:DeploymentProxy --broadcast --verify --rpc-url $ETH_RPC_LOCAL