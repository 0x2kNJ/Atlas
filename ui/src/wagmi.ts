import { createConfig, http } from "wagmi";
import { anvil } from "wagmi/chains";
import { injected } from "wagmi/connectors";

const RPC_URL = import.meta.env.VITE_RPC_URL || "http://127.0.0.1:8545";

export const config = createConfig({
  chains: [anvil],
  connectors: [injected()],
  transports: {
    [anvil.id]: http(RPC_URL),
  },
});
