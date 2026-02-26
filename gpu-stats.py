# nvitop Python script to log stats for all Nvidia GPUs, physical and MIG.
# You must run this within a venv that has nvitop installed.
# by Dan MacDonald 2026

import csv
import sys
from datetime import datetime
from nvitop import PhysicalDevice

def collect_gpu_stats():
    writer = csv.writer(sys.stdout)
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        phys_devices = PhysicalDevice.all()
        
        for p_dev in phys_devices:
            m_devices = p_dev.mig_devices()
            
            if m_devices:
                for m_dev in m_devices:
                    write_row(writer, timestamp, m_dev, parent=p_dev)
            else:
                write_row(writer, timestamp, p_dev, parent=p_dev)

    except Exception as e:
        print(f"Init error: {e}", file=sys.stderr)

def write_row(writer, timestamp, device, parent):
    try:
        # 1. PCI Address (from physical parent)
        pci = parent.pci_info()
        pci_address = pci.busId.decode('utf-8') if isinstance(pci.busId, bytes) else pci.busId

        # 2. Temperature (from physical parent)
        temp = parent.temperature()
        
        # 3. Utilization (Robust check)
        # We try to get it; if it fails or says N/A, we use 0
        try:
            gpu_util = device.gpu_utilization()
            if gpu_util is None or str(gpu_util) == 'N/A':
                gpu_util = 0
        except:
            gpu_util = 0
            
        # 4. Memory (Specific to this partition)
        mem_used = device.memory_used() / (1024**2)
        mem_total = device.memory_total() / (1024**2)
        
        # 5. UUID
        uuid = device.uuid()

        writer.writerow([
            timestamp,
            device.index,
            pci_address,
            temp,
            gpu_util,
            f"{mem_used:.2f}",
            f"{mem_total:.2f}",
            uuid
        ])
    except Exception as e:
        idx = getattr(device, 'index', 'unknown')
        print(f"Error on device {idx}: {e}", file=sys.stderr)

if __name__ == "__main__":
    collect_gpu_stats()
