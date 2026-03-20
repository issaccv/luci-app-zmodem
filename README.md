# luci-app-zmodem

RM520N 的 OpenWrt 控制页面，面向鲲鹏/NRadio C8-660 一类使用 Quectel RM520N-CN 的设备。

这个 fork 在原项目基础上补了两类能力：

- `router` 模式：保持原有思路，OpenWrt 自己通过基带数据口拿地址，再由路由器做 NAT。
- `passthrough` 模式：把基带数据口桥到一个独立 LAN 口，让下游设备直接从基带侧获取地址。

## 适用前提

这个项目默认假设：

- 基带控制面走 USB/AT/QMI。
- 基带数据面走独立以太网接口，而不是 `wwan0`。
- 在 C8-660 / WT9103 上，这个接口通常是 `eth1`。

如果你的板子不是这个拓扑，需要在 LuCI 里把“基带数据接口”改成实际设备名。

## 新增配置项

LuCI 的“常规设置”页新增了以下选项：

- `网络模式`
  - `路由/NAT`：OpenWrt 继续把基带口当 `wan` 使用。
  - `桥接透传`：OpenWrt 会把基带口和指定 `LAN` 口放进一个单独的 bridge。
- `基带数据接口`
  - 默认是 `eth1`。
- `透传LAN口`
  - 默认是 `lan4`。

桥接透传模式下，脚本会：

- 把选中的 `LAN` 口从 `br-lan` 中移除。
- 创建一个新的 bridge，默认名为 `br-modem`。
- 把 `eth1 + lanX` 放进这个 bridge。
- 把 `wan/wan6` 切成 `proto none`，避免路由器自己继续抢占基带分配的 IPv4/IPv6 地址。
- 关闭路由器侧的 `pingCheck`，因为桥接模式下公网地址不再挂在路由器自己身上。

## OpenWrt 侧配合修改

要让这个包在自编译 OpenWrt 上正常工作，至少要满足下面这些条件：

1. 板级网络定义必须把基带数据面映射到单独网口。
   以 WT9103/C8-660 为例，推荐让 `wan=eth1`。

2. DTS 需要正确描述第二个 GMAC 和对应 PHY。
   以 WT9103/C8-660 为例，`gmac1` 应该连到基带数据面所使用的 PHY。

3. 如果你使用的是自定义 OpenWrt 树，README 里描述的桥接功能只负责运行期 UCI/network 切换。
   板级 `DTS`、`02_network`、MAC 修正等工作仍然需要在主 OpenWrt 树中完成。

## 已知限制

- 透传模式需要独占一个 LAN 口；这个口不再属于 `br-lan`。
- 如果你当前就是从将被透传的那个 LAN 口管理路由器，切换模式后会立即断开。
- 公开仓库版本没有厂商私有的 `ipcheck.sh`。如果你从厂商固件移植了那套脚本，需要同步把“本机必须持有基带 IP”的假设改掉。
- 这个项目默认通过 `AT+QETH` 和 `AT+QMAP` 初始化 RM520N 的以太网数据面。首次启动时会显式写入 `AT+QMAP="IPPT_NAT",0`。

## 在 Orb / Linux 本地盘编译

如果你的 macOS 工作目录是大小写不敏感卷，不要直接在 `/Users/...` 下编译完整 OpenWrt。
建议把 OpenWrt 树放在 Orb 的 Linux 本地盘，例如 `/home/zhouquan/openwrt-nradio-25.12`。

典型流程：

```sh
orb
cd /home/zhouquan/openwrt-nradio-25.12/package/mtk
git clone https://github.com/issaccv/luci-app-zmodem.git
cd /home/zhouquan/openwrt-nradio-25.12
./scripts/feeds update luci
./scripts/feeds install luci-base
CMAKE_POLICY_VERSION_MINIMUM=3.5 make package/mtk/luci-app-zmodem/compile V=s
```

这一步之所以显式带上 `CMAKE_POLICY_VERSION_MINIMUM=3.5`，是因为某些较新的构建环境里，
`lucihttp` 依赖会触发 CMake 兼容策略错误：

```text
Compatibility with CMake < 3.5 has been removed
```

如果你的树没有这个问题，也可以去掉这个环境变量再试。

如果包尚未进入 `.config`，可以先执行：

```sh
./scripts/config setm PACKAGE_luci-app-zmodem
make defconfig
```

编译完成后，产物通常在：

```sh
bin/packages/aarch64_cortex-a53/base/
```

在我这次使用的 mt798x/OpenWrt 树里，最终产物格式是 `apk`，例如：

```sh
bin/packages/aarch64_cortex-a53/base/luci-app-zmodem-1.2.0-r2.apk
```

## 模式切换建议

对 C8-660 / WT9103 来说，更稳妥的桥接做法通常是：

- 管理网继续留在 `br-lan`。
- 选择一个独立口，例如 `lan4`，专门给基带透传。
- 如果你还需要路由器自己联网，请另配一条上行，或者保留 `router` 模式。
