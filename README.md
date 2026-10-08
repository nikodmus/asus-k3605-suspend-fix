# Asus Vivobook 16X (K3605) – fix for freeze on resume from suspend

**Symptom:** on Linux the laptop goes to sleep fine, but never wakes up. Black screen,
Caps Lock LED does not react, only a hard power-off helps. Windows sleeps normally.

**Cause:** the NVMe SSD (behind Intel VMD) does not come back from the **D3cold** power
state (power fully cut) during resume, and the whole machine locks up. The MediaTek
MT7922 Wi-Fi card has the same problem, but it "only" dies instead of freezing the system.

**Fix:** one udev rule that keeps those devices out of D3cold.

> Suomeksi: [lyhyt kuvaus alempana](#suomeksi).

## Who this is for

Tested on:

| | |
|---|---|
| Laptop | Asus Vivobook 16X **K3605VU**, BIOS K3605VU.317 |
| CPU / GPU | Intel Raptor Lake (13th gen) + NVIDIA RTX 4050 Laptop |
| SSD | Micron 2400 NVMe (1344:5413), behind Intel RST VMD (8086:a77f) |
| Wi-Fi | MediaTek MT7922 (14c3:7922) |
| OS | Fedora 44 KDE, kernel 7.2.7 |
| GPU mode | Integrated (supergfxctl). Hybrid not tested yet. |

Very likely the same issue as the unsolved
[Arch forum thread about the K3605VV](https://bbs.archlinux.org/viewtopic.php?id=292404)
(freeze after suspend on Arch, Debian, Fedora, Ubuntu; `sudo` hangs and network is broken
on the distros that do wake up – which is what a dead SSD and dead Wi-Fi look like).
The Wi-Fi part is also tracked in kernel
[bug 220399](https://bugzilla.kernel.org/show_bug.cgi?id=220399) (K3605ZU, Alder Lake), where
disabling D3cold for the MT7922 alone was enough. On the K3605VU (Raptor Lake) the NVMe behind VMD
needs it too.

If you have another K3605 variant, please open an issue and tell whether it worked.

Things that **did not** help (so you can skip them): kernels 6.19 and 7.2.7, nouveau vs.
NVIDIA 615 driver, `mem_sleep` s2idle vs. deep, switching the GPU to Integrated only
(supergfxctl), latest BIOS, Windows Fast Startup off.

## Install

```bash
sudo cp 99-asus-k3605-suspend-fix.rules /etc/udev/rules.d/
sudo reboot
```

After the reboot, check that it is active (every line should end in `d3cold=0`):

```bash
for d in $(lspci -Dn | awk '/0108|14c3:7922/{print $1}'); do
  for x in $d $(basename $(readlink -f /sys/bus/pci/devices/$d/..)); do
    echo "$x d3cold=$(cat /sys/bus/pci/devices/$x/d3cold_allowed)"; done; done
```

Then test with `systemctl suspend`.

**Uninstall:** `sudo rm /etc/udev/rules.d/99-asus-k3605-suspend-fix.rules` and reboot.

The rule only matches on boards whose DMI board name starts with `K3605`, so it is
harmless elsewhere. Side effect: sleep may use slightly more battery than on Windows,
because these devices stay in D3hot instead of being powered off completely.

## How the cause was found

The interesting part. All of this used standard kernel tools; the
[diagnostic script](diagnose-suspend.sh) in this repo automates each step.

### 1. Logs: the kernel never gets to write anything

Every failed boot ended with the same last line:

```
systemd-sleep: Performing sleep operation 'suspend'...
kernel: PM: suspend entry (s2idle)
```

Anything after that is lost because the disk is gone. `/sys/power/suspend_stats/success`
was `0` – suspend had never once worked on this install.

### 2. `pm_test`: which stage hangs?

`/sys/power/pm_test` makes the kernel run suspend only up to a given stage, wait 5 s
and resume by itself. Running the stages from shallowest to deepest:

| Stage | What it does | Result |
|---|---|---|
| `freezer` | freeze user space | ✅ OK |
| `devices` | normal device suspend callbacks | ✅ OK |
| `platform` | late/noirq suspend (PCI devices go to D3), ACPI s2idle calls | ❌ **freeze** |

So the problem is in the last device stage or in the firmware – not in user space,
not in the GPU driver.

### 3. `pm_trace`: where exactly?

With `/sys/power/pm_trace` enabled, the kernel stores a hash of the device it is
working on in the RTC (the hardware clock), which survives a reboot. After the
freeze and a quick reboot:

```
PM:   Magic number: 0:142:229
PM:   hash matches drivers/base/power/main.c:1107
acpi device:76: hash matches
```

`main.c:1107` is in `device_resume()`. So the machine **did** suspend and was already
**waking up** devices when it locked up. The device itself (`\_SB.PC00.SPI6`, an ACPI
node with no driver) was a red herring – async PCI resume runs in parallel, so the
real culprit is a PCI device that never came back.

### 4. D3cold bisection: which device?

The `platform` stage is where PCI devices can be put into D3cold. Six devices had
`d3cold_allowed=1`: the NVMe SSD, the Wi-Fi card, the NVIDIA GPU, and the PCIe port
above each of them.

| D3cold disabled on | `pm_test=platform` |
|---|---|
| all six | ✅ passes |
| NVIDIA + port only | ❌ freeze |
| NVMe + port only | ✅ passes – but Wi-Fi is dead afterwards |

The Wi-Fi failure in the last run:

```
mt7921e 0000:2c:00.0: driver own failed
mt7921e 0000:2c:00.0: PM: dpm_run_callback(): pci_pm_resume returns -5
ieee80211 phy0: PM: dpm_run_callback(): wiphy_resume [cfg80211] returns -110
```

**Result:** the NVMe SSD freezes the machine, the MT7922 dies on its own. With D3cold
disabled on both (and their ports), real `systemctl suspend` works and Wi-Fi survives.

### Related upstream work

The same class of bug was fixed in the kernel for the **Asus B1400**: there the NVMe
and its PCIe bridge could not come back from D3cold, and a PCI quirk now disables
D3cold on that bridge
([patch v3](https://lkml.iu.edu/hypermail/linux/kernel/2402.3/05167.html),
[patchwork](https://patchwork.ozlabs.org/project/linux-pci/patch/20240130183124.19985-1-drake@endlessos.org/),
upstream commit `cdea98bf1fae`). The K3605 is not covered by that quirk – it has a
different bridge (VMD) and different device IDs. A proper kernel quirk for the K3605
would make this repo unnecessary.

## Diagnostic script

```bash
sudo ./diagnose-suspend.sh status                  # sleep settings + D3cold state of all PCI devices
sudo ./diagnose-suspend.sh pmtest                  # step 2
sudo ./diagnose-suspend.sh trace                   # step 3
sudo ./diagnose-suspend.sh d3cold-test 0000:2c:00.0 0000:00:1c.0   # step 4
```

Everything is runtime-only and resets on reboot. Each step is written to
`suspend-diag.log` *before* it runs, so after a freeze the last line tells you where it hung.
Save your work first – some of these tests are expected to freeze the machine.

## How this was made

I debugged this together with an AI coding assistant (Claude Code) running in the
terminal on the affected laptop. The assistant read the logs, proposed each test and wrote
the scripts; I ran every test that needed root, rebooted after each freeze, reported
results and decided what to try next. Every claim in this README is backed by a log line
from those runs.

## Suomeksi

Asus Vivobook 16X (K3605) ei herännyt Linuxissa lepotilasta: kone jumittui kokonaan.
Syy selvitettiin `pm_test`- ja `pm_trace`-työkaluilla sekä puolittamalla epäiltyjä
laitteita: NVMe-levy (Intel VMD:n takana) ja MT7922-WLAN eivät palaa D3cold-tilasta.
Korjaus on yksi udev-sääntö, joka estää näitä laitteita menemästä D3cold-tilaan.
Asennus: kopioi `99-asus-k3605-suspend-fix.rules` kansioon `/etc/udev/rules.d/` ja
käynnistä kone uudelleen.

## License

MIT
