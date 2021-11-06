import { task } from "hardhat/config";
import {
  getEthersSignerByAddress,
  getParamPerNetwork,
  insertContractAddressInDb,
} from "../../helpers/contracts-helpers";
import { deployReserveOracle, deployInitializableAdminProxy } from "../../helpers/contracts-deployments";
import { ICommonConfiguration, eNetwork, eContractid } from "../../helpers/types";
import { waitForTx, notFalsyOrZeroAddress } from "../../helpers/misc-utils";
import { ConfigNames, loadPoolConfig, getWrappedNativeTokenAddress } from "../../helpers/configuration";
import {
  getReserveOracle,
  getLendPoolAddressesProvider,
  getPairsTokenAggregator,
  getBendProxyAdmin,
  getInitializableAdminProxy,
} from "../../helpers/contracts-getters";
import { ReserveOracle, InitializableAdminProxy } from "../../types";

task("full:deploy-oracle-reserve", "Deploy reserve oracle for full enviroment")
  .addFlag("verify", "Verify contracts at Etherscan")
  .addParam("pool", `Pool name to retrieve configuration, supported: ${Object.values(ConfigNames)}`)
  .setAction(async ({ verify, pool }, DRE) => {
    try {
      await DRE.run("set-DRE");
      const network = <eNetwork>DRE.network.name;
      const poolConfig = loadPoolConfig(pool);
      const { ReserveAssets, ReserveAggregator } = poolConfig as ICommonConfiguration;

      const addressesProvider = await getLendPoolAddressesProvider();
      const proxyAdmin = await getBendProxyAdmin(await addressesProvider.getProxyAdmin());
      const proxyOwnerAddress = await proxyAdmin.owner();

      const reserveOracleAddress = getParamPerNetwork(poolConfig.ReserveOracle, network);
      const reserveAssets = getParamPerNetwork(ReserveAssets, network);
      const reserveAggregators = getParamPerNetwork(ReserveAggregator, network);

      const [tokens, aggregators] = getPairsTokenAggregator(
        reserveAssets,
        reserveAggregators,
        poolConfig.OracleQuoteCurrency
      );

      const weth = await getWrappedNativeTokenAddress(poolConfig);

      const reserveOracleImpl = await deployReserveOracle([], verify);
      const initEncodedData = reserveOracleImpl.interface.encodeFunctionData("initialize", [weth]);

      let reserveOracle: ReserveOracle;
      let reserveOracleProxy: InitializableAdminProxy;

      if (notFalsyOrZeroAddress(reserveOracleAddress)) {
        console.log("Upgrading exist reserve oracle proxy to new implementation...");

        await insertContractAddressInDb(eContractid.ReserveOracle, reserveOracleAddress);

        reserveOracleProxy = await getInitializableAdminProxy(reserveOracleAddress);
        // only proxy admin can do upgrading
        const ownerSigner = DRE.ethers.provider.getSigner(proxyOwnerAddress);
        await waitForTx(
          await proxyAdmin.connect(ownerSigner).upgrade(reserveOracleProxy.address, reserveOracleImpl.address)
        );

        reserveOracle = await getReserveOracle(reserveOracleProxy.address);
      } else {
        console.log("Deploying new reserve oracle proxy & implementation...");

        reserveOracleProxy = await deployInitializableAdminProxy(eContractid.ReserveOracle, proxyAdmin.address, verify);

        await waitForTx(await reserveOracleProxy.initialize(reserveOracleImpl.address, initEncodedData));

        reserveOracle = await getReserveOracle(reserveOracleProxy.address);

        const oracleOwnerSigner = await getEthersSignerByAddress(await reserveOracle.owner());
        await waitForTx(await reserveOracle.connect(oracleOwnerSigner).setAggregators(tokens, aggregators));
      }

      // Register the proxy oracle on the addressesProvider
      await waitForTx(await addressesProvider.setReserveOracle(reserveOracle.address));

      console.log("Reserve Oracle: proxy %s, implementation %s", reserveOracle.address, reserveOracleImpl.address);
    } catch (error) {
      throw error;
    }
  });
