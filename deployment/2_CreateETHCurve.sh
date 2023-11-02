mnemonic=$FOUNDRY_TEST_MNEMONIC
rpc=$TENDERLY_RPC 
empty_address=$(cast --address-zero)
initial_lp_holder=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
initial_reserve=$(cast --to-wei 1 ether)
echo "Create ibETH curve"
cast send --mnemonic="$mnemonic" --rpc-url=$rpc $IBC_FACTORY_CONTRACT_ADDRESS --value $initial_reserve \
    "createCurve(uint256,address,address)" $initial_reserve $empty_address $initial_lp_holder

# get curve address

call_result=$(cast call  --rpc-url=$rpc $IBC_FACTORY_CONTRACT_ADDRESS "getCurve(address)" $empty_address)
curve_address=$(cast --abi-decode "func()(address)" $call_result)
call_result=$(cast call  --rpc-url=$rpc $curve_address "inverseTokenAddress()" )
ibeth_address=$(cast --abi-decode "func()(address)" $call_result)
export IBC_IBETH_CURVE_CONTRACT_ADDRESS=$curve_address
echo "ibETH curve address: $curve_address"
echo "ibETH token address: $ibeth_address"