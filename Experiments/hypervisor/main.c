// oriel-hv: experimental virtual machine monitor built directly on Hypervisor.framework.
// Boots an arm64 Linux kernel on a PL011 serial console, with GICv3, PSCI and a virtio-mmio block disk.
// Build and run: Experiments/hypervisor/run.sh (signs with com.apple.security.hypervisor).
// Requires macOS 15 or later for the framework-provided GICv3 (hv_gic_*).

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <termios.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
#include <zlib.h>
#include <Hypervisor/Hypervisor.h>

// hv_gic_* is macOS 15+; main() checks the OS version once instead of guarding every call.
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

#define HV_CHECK(expr) do {                                                  \
    hv_return_t _r = (expr);                                                 \
    if (_r != HV_SUCCESS) {                                                  \
        fprintf(stderr, "%s failed with error 0x%x\n", #expr, (unsigned)_r); \
        exit(1);                                                             \
    }                                                                        \
} while (0)

#define RAM_BASE        0x40000000ULL
#define GIC_DIST_BASE   0x08000000ULL
#define GIC_REDIST_BASE 0x0C000000ULL
#define UART_BASE       0x09000000ULL
#define UART_SIZE       0x00001000ULL
#define VIRTIO_BASE     0x0A000000ULL
#define VIRTIO_SIZE     0x00000200ULL

#define MAX_CPUS        16
#define UART_RX_CAP     2048

static void *g_ram_ptr = NULL;
static uint64_t g_ram_base = RAM_BASE;
static uint64_t g_ram_size = 0;
static uint32_t g_num_cpus = 2;
static volatile bool g_shutdown = false;
static uint64_t g_boot_pc = 0;
static uint64_t g_boot_dtb = 0;

static inline void *ipa_to_hva(uint64_t ipa, size_t len) {
    if (ipa >= g_ram_base && (ipa + len) <= (g_ram_base + g_ram_size) && (ipa + len) >= ipa) {
        return (uint8_t *)g_ram_ptr + (ipa - g_ram_base);
    }
    return NULL;
}

// -----------------------------------------------------------------------------
// FDT Builder
// -----------------------------------------------------------------------------

#define FDT_MAGIC 0xd00dfeed
#define FDT_BEGIN_NODE 1
#define FDT_END_NODE   2
#define FDT_PROP       3
#define FDT_NOP        4
#define FDT_END        9

typedef struct {
    uint8_t *s_buf;
    size_t s_len;
    size_t s_cap;
    char *str_buf;
    size_t str_len;
    size_t str_cap;
} fdt_t;

static void fdt_init(fdt_t *f) {
    f->s_cap = 65536;
    f->s_buf = malloc(f->s_cap);
    f->s_len = 0;
    f->str_cap = 8192;
    f->str_buf = malloc(f->str_cap);
    f->str_len = 0;
}

static void fdt_put_u32(fdt_t *f, uint32_t v) {
    if (f->s_len + 4 > f->s_cap) {
        f->s_cap *= 2;
        f->s_buf = realloc(f->s_buf, f->s_cap);
    }
    uint32_t b = htonl(v);
    memcpy(f->s_buf + f->s_len, &b, 4);
    f->s_len += 4;
}

static uint32_t fdt_add_str(fdt_t *f, const char *s) {
    for (size_t i = 0; i < f->str_len; ) {
        if (strcmp(f->str_buf + i, s) == 0) return (uint32_t)i;
        i += strlen(f->str_buf + i) + 1;
    }
    size_t slen = strlen(s) + 1;
    while (f->str_len + slen > f->str_cap) {
        f->str_cap *= 2;
        f->str_buf = realloc(f->str_buf, f->str_cap);
    }
    uint32_t off = (uint32_t)f->str_len;
    memcpy(f->str_buf + f->str_len, s, slen);
    f->str_len += slen;
    return off;
}

static void fdt_begin_node(fdt_t *f, const char *name) {
    fdt_put_u32(f, FDT_BEGIN_NODE);
    size_t nlen = strlen(name) + 1;
    size_t pad = (4 - (nlen % 4)) % 4;
    size_t total = nlen + pad;
    while (f->s_len + total > f->s_cap) {
        f->s_cap *= 2;
        f->s_buf = realloc(f->s_buf, f->s_cap);
    }
    memcpy(f->s_buf + f->s_len, name, nlen);
    memset(f->s_buf + f->s_len + nlen, 0, pad);
    f->s_len += total;
}

static void fdt_end_node(fdt_t *f) {
    fdt_put_u32(f, FDT_END_NODE);
}

static void fdt_prop(fdt_t *f, const char *name, const void *val, uint32_t len) {
    fdt_put_u32(f, FDT_PROP);
    fdt_put_u32(f, len);
    fdt_put_u32(f, fdt_add_str(f, name));
    size_t pad = (4 - (len % 4)) % 4;
    while (f->s_len + len + pad > f->s_cap) {
        f->s_cap *= 2;
        f->s_buf = realloc(f->s_buf, f->s_cap);
    }
    if (len > 0) memcpy(f->s_buf + f->s_len, val, len);
    if (pad > 0) memset(f->s_buf + f->s_len + len, 0, pad);
    f->s_len += len + pad;
}

static void fdt_prop_u32(fdt_t *f, const char *name, uint32_t val) {
    uint32_t b = htonl(val);
    fdt_prop(f, name, &b, 4);
}

static void fdt_prop_u64(fdt_t *f, const char *name, uint64_t val) {
    uint32_t b[2] = { htonl(val >> 32), htonl(val & 0xffffffff) };
    fdt_prop(f, name, b, 8);
}

static void fdt_prop_str(fdt_t *f, const char *name, const char *val) {
    fdt_prop(f, name, val, (uint32_t)(strlen(val) + 1));
}

static void *fdt_finish(fdt_t *f, size_t *out_size) {
    fdt_put_u32(f, FDT_END);
    size_t hdr_sz = 40;
    size_t rsv_sz = 16;
    size_t s_off = hdr_sz + rsv_sz;
    size_t str_off = s_off + f->s_len;
    size_t total = str_off + f->str_len;

    uint8_t *blob = calloc(1, total);
    uint32_t *h = (uint32_t *)blob;
    h[0] = htonl(FDT_MAGIC);
    h[1] = htonl((uint32_t)total);
    h[2] = htonl((uint32_t)s_off);
    h[3] = htonl((uint32_t)str_off);
    h[4] = htonl((uint32_t)hdr_sz);
    h[5] = htonl(17);
    h[6] = htonl(16);
    h[7] = htonl(0);
    h[8] = htonl((uint32_t)f->str_len);
    h[9] = htonl((uint32_t)f->s_len);

    memcpy(blob + s_off, f->s_buf, f->s_len);
    memcpy(blob + str_off, f->str_buf, f->str_len);
    free(f->s_buf);
    free(f->str_buf);
    *out_size = total;
    return blob;
}

// -----------------------------------------------------------------------------
// vCPU State & Kicking
// -----------------------------------------------------------------------------

typedef struct {
    uint32_t id;
    pthread_t thread;
    hv_vcpu_t vcpu;
    hv_vcpu_exit_t *exit;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    bool created;
    bool running;
    uint64_t entry_pc;
    uint64_t context_arg;
} vcpu_state_t;

static vcpu_state_t g_vcpus[MAX_CPUS];

static void kick_all_vcpus(void) {
    for (uint32_t i = 0; i < g_num_cpus; i++) {
        pthread_mutex_lock(&g_vcpus[i].lock);
        pthread_cond_signal(&g_vcpus[i].cond);
        pthread_mutex_unlock(&g_vcpus[i].lock);
        if (g_vcpus[i].created) {
            hv_vcpus_exit(&g_vcpus[i].vcpu, 1);
        }
    }
}

// -----------------------------------------------------------------------------
// PL011 UART
// -----------------------------------------------------------------------------

typedef struct {
    pthread_mutex_t lock;
    uint8_t rx_fifo[UART_RX_CAP];
    uint32_t rx_head;
    uint32_t rx_tail;
    uint32_t rx_count;
    uint32_t ibrd;
    uint32_t fbrd;
    uint32_t lcr_h;
    uint32_t cr;
    uint32_t ifls;
    uint32_t imsc;
    uint32_t ris;
    uint32_t dmacr;
    uint32_t spi_id;
    bool irq_line;
} pl011_t;

static pl011_t g_uart;

static void uart_update_irq(pl011_t *u) {
    if (u->rx_count > 0) u->ris |= (1u << 4);
    else u->ris &= ~(1u << 4);

    bool asserted = (u->ris & u->imsc) != 0;
    if (asserted != u->irq_line) {
        u->irq_line = asserted;
        hv_gic_set_spi(u->spi_id, asserted);
    }
}

static uint64_t uart_read(pl011_t *u, uint64_t off, size_t size) {
    pthread_mutex_lock(&u->lock);
    uint64_t val = 0;
    switch (off) {
        case 0x000: // DR
            if (u->rx_count > 0) {
                val = u->rx_fifo[u->rx_head];
                u->rx_head = (u->rx_head + 1) % UART_RX_CAP;
                u->rx_count--;
                uart_update_irq(u);
            }
            break;
        case 0x004: // RSR/ECR
            val = 0;
            break;
        case 0x018: // FR
            val = (1u << 7); // TXFE
            if (u->rx_count == 0) val |= (1u << 4); // RXFE
            if (u->rx_count == UART_RX_CAP) val |= (1u << 6); // RXFF
            break;
        case 0x024: val = u->ibrd; break;
        case 0x028: val = u->fbrd; break;
        case 0x02C: val = u->lcr_h; break;
        case 0x030: val = u->cr; break;
        case 0x034: val = u->ifls; break;
        case 0x038: val = u->imsc; break;
        case 0x03C: val = u->ris; break;
        case 0x040: val = (u->ris & u->imsc); break;
        case 0x048: val = u->dmacr; break;
        case 0xFE0: val = 0x11; break;
        case 0xFE4: val = 0x10; break;
        case 0xFE8: val = 0x14; break;
        case 0xFEC: val = 0x00; break;
        case 0xFF0: val = 0x0D; break;
        case 0xFF4: val = 0xF0; break;
        case 0xFF8: val = 0x05; break;
        case 0xFFC: val = 0xB1; break;
        default: val = 0; break;
    }
    pthread_mutex_unlock(&u->lock);
    return val;
}

static void uart_write(pl011_t *u, uint64_t off, uint64_t val, size_t size) {
    pthread_mutex_lock(&u->lock);
    switch (off) {
        case 0x000: { // DR
            uint8_t c = (uint8_t)val;
            write(STDOUT_FILENO, &c, 1);
            u->ris |= (1u << 5); // TX RIS
            uart_update_irq(u);
            break;
        }
        case 0x004: break; // ECR
        case 0x024: u->ibrd = (uint32_t)val; break;
        case 0x028: u->fbrd = (uint32_t)val; break;
        case 0x02C: u->lcr_h = (uint32_t)val; break;
        case 0x030: u->cr = (uint32_t)val; break;
        case 0x034: u->ifls = (uint32_t)val; break;
        case 0x038: // IMSC
            u->imsc = (uint32_t)val;
            uart_update_irq(u);
            break;
        case 0x044: // ICR
            u->ris &= ~((uint32_t)val);
            uart_update_irq(u);
            break;
        case 0x048: u->dmacr = (uint32_t)val; break;
        default: break;
    }
    pthread_mutex_unlock(&u->lock);
}

static void uart_push_rx(pl011_t *u, uint8_t c) {
    pthread_mutex_lock(&u->lock);
    if (u->rx_count < UART_RX_CAP) {
        u->rx_fifo[u->rx_tail] = c;
        u->rx_tail = (u->rx_tail + 1) % UART_RX_CAP;
        u->rx_count++;
        uart_update_irq(u);
        kick_all_vcpus();
    }
    pthread_mutex_unlock(&u->lock);
}

// -----------------------------------------------------------------------------
// Virtio-MMIO Block Device (v2 / Modern)
// -----------------------------------------------------------------------------

struct vring_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
};

struct vring_avail {
    uint16_t flags;
    uint16_t idx;
    uint16_t ring[256];
};

struct vring_used_elem {
    uint32_t id;
    uint32_t len;
};

struct vring_used {
    uint16_t flags;
    uint16_t idx;
    struct vring_used_elem ring[256];
};

typedef struct {
    pthread_mutex_t lock;
    int disk_fd;
    bool readonly;
    uint64_t capacity_sectors;
    uint32_t spi_id;

    uint32_t dev_feat_sel;
    uint32_t drv_feat_sel;
    uint32_t drv_feat;
    uint32_t queue_sel;
    uint32_t queue_num;
    uint32_t queue_ready;
    uint64_t queue_desc;
    uint64_t queue_driver;
    uint64_t queue_device;
    uint16_t last_avail_idx;

    uint32_t status;
    uint32_t interrupt_status;
} virtio_blk_t;

static virtio_blk_t g_virtio;
static bool g_has_disk = false;

static void virtio_blk_process(virtio_blk_t *v) {
    if (!v->queue_ready || v->queue_num == 0) return;
    struct vring_avail *avail = ipa_to_hva(v->queue_driver, sizeof(struct vring_avail));
    struct vring_used *used = ipa_to_hva(v->queue_device, sizeof(struct vring_used));
    struct vring_desc *desc = ipa_to_hva(v->queue_desc, v->queue_num * sizeof(struct vring_desc));
    if (!avail || !used || !desc) return;

    bool did_work = false;
    while (v->last_avail_idx != avail->idx) {
        uint16_t head = avail->ring[v->last_avail_idx % v->queue_num];
        uint16_t cur = head;
        uint32_t req_type = 0;
        uint64_t sector = 0;
        uint8_t *status_ptr = NULL;
        uint32_t written = 0;
        uint8_t res_status = 0; // VIRTIO_BLK_S_OK
        bool is_hdr = true;

        while (1) {
            if (cur >= v->queue_num) break;
            struct vring_desc *d = &desc[cur];
            bool has_next = (d->flags & 1) != 0;

            if (is_hdr) {
                void *hdr_buf = ipa_to_hva(d->addr, d->len);
                if (hdr_buf && d->len >= 16) {
                    req_type = *(uint32_t *)hdr_buf;
                    sector = *(uint64_t *)((uint8_t *)hdr_buf + 8);
                }
                is_hdr = false;
            } else if (!has_next) {
                status_ptr = (uint8_t *)ipa_to_hva(d->addr, 1);
            } else {
                void *buf = ipa_to_hva(d->addr, d->len);
                off_t offset = (off_t)sector * 512;
                if (buf) {
                    if (req_type == 0) { // VIRTIO_BLK_T_IN
                        ssize_t n = pread(v->disk_fd, buf, d->len, offset);
                        if (n < (ssize_t)d->len) {
                            if (n > 0) memset((uint8_t *)buf + n, 0, d->len - n);
                            else memset(buf, 0, d->len);
                        }
                        written += d->len;
                    } else if (req_type == 1) { // VIRTIO_BLK_T_OUT
                        if (v->readonly) {
                            res_status = 1;
                        } else {
                            ssize_t n = pwrite(v->disk_fd, buf, d->len, offset);
                            if (n < (ssize_t)d->len) res_status = 1;
                        }
                    } else if (req_type == 8) { // VIRTIO_BLK_T_GET_ID
                        const char *id = "oriel";
                        size_t l = strlen(id);
                        if (l > d->len) l = d->len;
                        memcpy(buf, id, l);
                        if (d->len > l) memset((uint8_t *)buf + l, 0, d->len - l);
                        written += d->len;
                    }
                }
            }

            if (has_next) cur = d->next;
            else break;
        }

        if (req_type == 4) fsync(v->disk_fd); // FLUSH
        if (status_ptr) {
            *status_ptr = res_status;
            written += 1;
        }

        uint16_t uidx = used->idx;
        used->ring[uidx % v->queue_num].id = head;
        used->ring[uidx % v->queue_num].len = written;
        __sync_synchronize();
        used->idx = uidx + 1;
        __sync_synchronize();

        v->last_avail_idx++;
        did_work = true;
    }

    if (did_work) {
        v->interrupt_status |= 1;
        hv_gic_set_spi(v->spi_id, true);
        kick_all_vcpus();
    }
}

static uint64_t virtio_read(virtio_blk_t *v, uint64_t off, size_t size) {
    pthread_mutex_lock(&v->lock);
    uint64_t val = 0;
    if (off >= 0x100 && off < 0x108) {
        if (off == 0x100 && size == 8) val = v->capacity_sectors;
        else if (off == 0x100 && size == 4) val = (uint32_t)v->capacity_sectors;
        else if (off == 0x104 && size == 4) val = (uint32_t)(v->capacity_sectors >> 32);
        pthread_mutex_unlock(&v->lock);
        return val;
    }
    switch (off) {
        case 0x000: val = 0x74726976; break; // "virt"
        case 0x004: val = 2; break;          // version
        case 0x008: val = 2; break;          // block
        case 0x00C: val = 0x554D4551; break; // "QEMU"
        case 0x010:                          // DeviceFeatures
            if (v->dev_feat_sel == 0) {
                val = (1u << 9); // FLUSH
                if (v->readonly) val |= (1u << 5); // RO
            } else if (v->dev_feat_sel == 1) {
                val = 1u; // VIRTIO_F_VERSION_1 (bit 32)
            }
            break;
        case 0x034: val = (v->queue_sel == 0) ? 256 : 0; break;
        case 0x044: val = (v->queue_sel == 0) ? v->queue_ready : 0; break;
        case 0x060: val = v->interrupt_status; break;
        case 0x070: val = v->status; break;
        case 0x0FC: val = 0; break;
        default: val = 0; break;
    }
    pthread_mutex_unlock(&v->lock);
    return val;
}

static void virtio_write(virtio_blk_t *v, uint64_t off, uint64_t val, size_t size) {
    pthread_mutex_lock(&v->lock);
    switch (off) {
        case 0x014: v->dev_feat_sel = (uint32_t)val; break;
        case 0x020: v->drv_feat = (uint32_t)val; break;
        case 0x024: v->drv_feat_sel = (uint32_t)val; break;
        case 0x030: v->queue_sel = (uint32_t)val; break;
        case 0x038: v->queue_num = (uint32_t)val; break;
        case 0x044: v->queue_ready = (uint32_t)val; break;
        case 0x050:
            if (val == 0) virtio_blk_process(v);
            break;
        case 0x064: // InterruptACK
            v->interrupt_status &= ~((uint32_t)val);
            if (v->interrupt_status == 0) {
                hv_gic_set_spi(v->spi_id, false);
            }
            break;
        case 0x070: // Status
            v->status = (uint32_t)val;
            if (v->status == 0) {
                v->queue_ready = 0;
                v->last_avail_idx = 0;
                v->interrupt_status = 0;
                hv_gic_set_spi(v->spi_id, false);
            }
            break;
        case 0x080: v->queue_desc = (v->queue_desc & 0xFFFFFFFF00000000ULL) | (uint32_t)val; break;
        case 0x084: v->queue_desc = (v->queue_desc & 0x00000000FFFFFFFFULL) | (val << 32); break;
        case 0x090: v->queue_driver = (v->queue_driver & 0xFFFFFFFF00000000ULL) | (uint32_t)val; break;
        case 0x094: v->queue_driver = (v->queue_driver & 0x00000000FFFFFFFFULL) | (val << 32); break;
        case 0x0A0: v->queue_device = (v->queue_device & 0xFFFFFFFF00000000ULL) | (uint32_t)val; break;
        case 0x0A4: v->queue_device = (v->queue_device & 0x00000000FFFFFFFFULL) | (val << 32); break;
        default: break;
    }
    pthread_mutex_unlock(&v->lock);
}

// -----------------------------------------------------------------------------
// Terminal & Stdin Reader
// -----------------------------------------------------------------------------

static struct termios g_orig_termios;
static bool g_termios_saved = false;

static void restore_terminal(void) {
    if (g_termios_saved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_orig_termios);
        g_termios_saved = false;
    }
}

static void setup_terminal(void) {
    if (isatty(STDIN_FILENO)) {
        if (tcgetattr(STDIN_FILENO, &g_orig_termios) == 0) {
            g_termios_saved = true;
            atexit(restore_terminal);
            struct termios raw = g_orig_termios;
            cfmakeraw(&raw);
            tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        }
    }
}

static void *stdin_thread_func(void *arg) {
    bool ctrl_a = false;
    uint8_t c;
    while (!g_shutdown) {
        ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n <= 0) break;
        if (ctrl_a) {
            ctrl_a = false;
            if (c == 'x' || c == 'X') {
                g_shutdown = true;
                kick_all_vcpus();
                break;
            }
            if (c == 0x01) {
                uart_push_rx(&g_uart, 0x01);
            } else {
                uart_push_rx(&g_uart, 0x01);
                uart_push_rx(&g_uart, c);
            }
        } else {
            if (c == 0x01) {
                ctrl_a = true;
            } else {
                uart_push_rx(&g_uart, c);
            }
        }
    }
    return NULL;
}

// -----------------------------------------------------------------------------
// PSCI / SMCCC & Exit Dispatch
// -----------------------------------------------------------------------------

static int64_t handle_psci(vcpu_state_t *vcpu, uint64_t func, uint64_t x1, uint64_t x2, uint64_t x3) {
    uint32_t fid = (uint32_t)func;
    switch (fid) {
        case 0x84000000: return 0x00010000; // PSCI_VERSION 1.0
        case 0x8400000A: // PSCI_FEATURES
            if (x1 == 0x84000000 || x1 == 0x84000002 || x1 == 0x8400000A ||
                x1 == 0x84000008 || x1 == 0x84000009 || x1 == 0xC4000003 ||
                x1 == 0x84000003 || x1 == 0xC4000004 || x1 == 0x84000004) return 0;
            return -1;
        case 0xC4000003: // CPU_ON (64-bit)
        case 0x84000003: { // CPU_ON (32-bit)
            uint32_t target = (uint32_t)(x1 & 0xFF);
            if (target >= g_num_cpus) return -2; // PSCI_INVALID_PARAMETERS
            pthread_mutex_lock(&g_vcpus[target].lock);
            if (g_vcpus[target].running) {
                pthread_mutex_unlock(&g_vcpus[target].lock);
                return -4; // PSCI_ALREADY_ON
            }
            g_vcpus[target].entry_pc = x2;
            g_vcpus[target].context_arg = x3;
            g_vcpus[target].running = true;
            pthread_cond_signal(&g_vcpus[target].cond);
            pthread_mutex_unlock(&g_vcpus[target].lock);
            return 0;
        }
        case 0x84000002: { // CPU_OFF
            pthread_mutex_lock(&vcpu->lock);
            vcpu->running = false;
            while (!vcpu->running && !g_shutdown) {
                pthread_cond_wait(&vcpu->cond, &vcpu->lock);
            }
            if (vcpu->running && !g_shutdown) {
                hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, vcpu->entry_pc);
                hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X0, vcpu->context_arg);
                hv_vcpu_set_reg(vcpu->vcpu, HV_REG_CPSR, 0x3c5);
            }
            pthread_mutex_unlock(&vcpu->lock);
            return 0;
        }
        case 0xC4000004: // AFFINITY_INFO (64-bit)
        case 0x84000004: { // AFFINITY_INFO (32-bit)
            uint32_t target = (uint32_t)(x1 & 0xFF);
            if (target >= g_num_cpus) return 1; // PSCI_AFFINITY_INFO_OFF
            return g_vcpus[target].running ? 0 : 1;
        }
        case 0x84000008: // SYSTEM_OFF
        case 0x84000009: // SYSTEM_RESET
            g_shutdown = true;
            kick_all_vcpus();
            restore_terminal();
            exit(0);
        case 0x84000006: return 2; // MIGRATE_INFO_TYPE: not supported
        case 0x80000000: return 0x10001; // SMCCC_VERSION 1.1
        case 0x80000001: return -1; // SMCCC_ARCH_FEATURES
        default: return -1; // NOT_SUPPORTED
    }
}

static void handle_data_abort(vcpu_state_t *vcpu, uint64_t esr, uint64_t ipa) {
    bool isv = (esr >> 24) & 1;
    if (!isv) {
        fprintf(stderr, "Data abort at 0x%llx without ISV\n", (unsigned long long)ipa);
        exit(1);
    }
    uint32_t sas = (esr >> 22) & 3;
    size_t size = 1u << sas;
    bool sse = (esr >> 21) & 1;
    uint32_t srt = (esr >> 16) & 0x1F;
    bool wnr = (esr >> 6) & 1;

    if (wnr) {
        uint64_t wval = 0;
        if (srt != 31) HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, (hv_reg_t)(HV_REG_X0 + srt), &wval));
        if (sas == 0) wval = (uint8_t)wval;
        else if (sas == 1) wval = (uint16_t)wval;
        else if (sas == 2) wval = (uint32_t)wval;

        if (ipa >= UART_BASE && ipa < UART_BASE + UART_SIZE) {
            uart_write(&g_uart, ipa - UART_BASE, wval, size);
        } else if (g_has_disk && ipa >= VIRTIO_BASE && ipa < VIRTIO_BASE + VIRTIO_SIZE) {
            virtio_write(&g_virtio, ipa - VIRTIO_BASE, wval, size);
        } else {
            static bool mmio_warn = false;
            if (!mmio_warn) {
                fprintf(stderr, "Unhandled MMIO write to 0x%llx\n", (unsigned long long)ipa);
                mmio_warn = true;
            }
        }
    } else {
        uint64_t rval = 0;
        if (ipa >= UART_BASE && ipa < UART_BASE + UART_SIZE) {
            rval = uart_read(&g_uart, ipa - UART_BASE, size);
        } else if (g_has_disk && ipa >= VIRTIO_BASE && ipa < VIRTIO_BASE + VIRTIO_SIZE) {
            rval = virtio_read(&g_virtio, ipa - VIRTIO_BASE, size);
        } else {
            static bool mmio_warn = false;
            if (!mmio_warn) {
                fprintf(stderr, "Unhandled MMIO read from 0x%llx\n", (unsigned long long)ipa);
                mmio_warn = true;
            }
        }

        if (sse) {
            if (sas == 0) rval = (int64_t)(int8_t)rval;
            else if (sas == 1) rval = (int64_t)(int16_t)rval;
            else if (sas == 2) rval = (int64_t)(int32_t)rval;
        } else {
            if (sas == 0) rval = (uint8_t)rval;
            else if (sas == 1) rval = (uint16_t)rval;
            else if (sas == 2) rval = (uint32_t)rval;
        }
        if (srt != 31) HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, (hv_reg_t)(HV_REG_X0 + srt), rval));
    }

    uint64_t pc;
    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc));
    HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, pc + 4));
}

static void handle_wfi(vcpu_state_t *vcpu) {
    uint64_t ctl = 0, cval = 0;
    HV_CHECK(hv_vcpu_get_sys_reg(vcpu->vcpu, HV_SYS_REG_CNTV_CTL_EL0, &ctl));
    HV_CHECK(hv_vcpu_get_sys_reg(vcpu->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cval));

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);

    uint64_t ns_to_wait = 10000000ULL; // 10 ms max
    if (ctl & 1) { // ENABLE
        uint64_t voff = 0;
        HV_CHECK(hv_vcpu_get_vtimer_offset(vcpu->vcpu, &voff));
        uint64_t now_ticks = mach_absolute_time();
        uint64_t deadline_ticks = cval + voff;
        if (deadline_ticks <= now_ticks) {
            ns_to_wait = 0;
        } else {
            uint64_t diff = deadline_ticks - now_ticks;
            uint64_t diff_ns = (diff * tb.numer) / tb.denom;
            if (diff_ns < ns_to_wait) ns_to_wait = diff_ns;
        }
    }

    if (ns_to_wait > 0 && !g_shutdown) {
        struct timespec ts;
        ts.tv_sec = ns_to_wait / 1000000000ULL;
        ts.tv_nsec = ns_to_wait % 1000000000ULL;
        pthread_mutex_lock(&vcpu->lock);
        pthread_cond_timedwait_relative_np(&vcpu->cond, &vcpu->lock, &ts);
        pthread_mutex_unlock(&vcpu->lock);
    }

    uint64_t pc;
    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc));
    HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, pc + 4));
}

static void *vcpu_thread_func(void *arg) {
    vcpu_state_t *vcpu = (vcpu_state_t *)arg;
    HV_CHECK(hv_vcpu_create(&vcpu->vcpu, &vcpu->exit, NULL));

    uint64_t mpidr = 0x80000000ULL | (uint64_t)vcpu->id;
    HV_CHECK(hv_vcpu_set_sys_reg(vcpu->vcpu, HV_SYS_REG_MPIDR_EL1, mpidr));

    pthread_mutex_lock(&vcpu->lock);
    vcpu->created = true;
    pthread_cond_broadcast(&vcpu->cond);

    if (vcpu->id > 0) {
        while (!vcpu->running && !g_shutdown) {
            pthread_cond_wait(&vcpu->cond, &vcpu->lock);
        }
        if (g_shutdown) {
            pthread_mutex_unlock(&vcpu->lock);
            hv_vcpu_destroy(vcpu->vcpu);
            return NULL;
        }
        hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, vcpu->entry_pc);
        hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X0, vcpu->context_arg);
        hv_vcpu_set_reg(vcpu->vcpu, HV_REG_CPSR, 0x3c5);
    }
    if (vcpu->id == 0) {
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, g_boot_pc));
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X0, g_boot_dtb));
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X1, 0));
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X2, 0));
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X3, 0));
        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_CPSR, 0x3c5));
        HV_CHECK(hv_vcpu_set_sys_reg(vcpu->vcpu, HV_SYS_REG_SCTLR_EL1, 0x30d00800));
    }
    pthread_mutex_unlock(&vcpu->lock);

    while (!g_shutdown) {
        hv_return_t ret = hv_vcpu_run(vcpu->vcpu);
        if (ret != HV_SUCCESS) {
            fprintf(stderr, "hv_vcpu_run failed: 0x%x\n", ret);
            break;
        }
        if (g_shutdown) break;

        switch (vcpu->exit->reason) {
            case HV_EXIT_REASON_CANCELED:
                break;
            case HV_EXIT_REASON_VTIMER_ACTIVATED: {
                HV_CHECK(hv_gic_set_redistributor_reg(vcpu->vcpu, HV_GIC_REDISTRIBUTOR_REG_GICR_ISPENDR0, 1u << 27));
                uint64_t ctl = 0;
                HV_CHECK(hv_vcpu_get_sys_reg(vcpu->vcpu, HV_SYS_REG_CNTV_CTL_EL0, &ctl));
                if (!((ctl & 1) && (ctl & 4) && !(ctl & 2))) {
                    HV_CHECK(hv_vcpu_set_vtimer_mask(vcpu->vcpu, false));
                }
                break;
            }
            case HV_EXIT_REASON_EXCEPTION: {
                uint64_t esr = vcpu->exit->exception.syndrome;
                uint32_t ec = (esr >> 26) & 0x3F;
                if (ec == 0x24) { // Data abort from lower EL
                    handle_data_abort(vcpu, esr, vcpu->exit->exception.physical_address);
                } else if (ec == 0x16 || ec == 0x17) { // HVC (0x16) or SMC (0x17)
                    uint64_t x0, x1, x2, x3;
                    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_X0, &x0));
                    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_X1, &x1));
                    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_X2, &x2));
                    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_X3, &x3));
                    int64_t r = handle_psci(vcpu, x0, x1, x2, x3);
                    if ((uint32_t)x0 == 0x84000002) break; // CPU_OFF: resumed at a new entry point
                    HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_X0, (uint64_t)r));
                    if (ec == 0x17) { // SMC advances PC
                        uint64_t pc;
                        HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc));
                        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, pc + 4));
                    }
                } else if (ec == 0x18) { // MSR / MRS
                    static bool msr_logged = false;
                    if (!msr_logged) {
                        fprintf(stderr, "Trapped MSR/MRS (ESR=0x%llx), RAZ/WI\n", (unsigned long long)esr);
                        msr_logged = true;
                    }
                    if (esr & 1) { // MRS (read)
                        uint32_t rt = (esr >> 5) & 0x1F;
                        if (rt != 31) HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, (hv_reg_t)(HV_REG_X0 + rt), 0));
                    }
                    uint64_t pc;
                    HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc));
                    HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, pc + 4));
                } else if (ec == 0x01) { // WFI / WFE
                    if (esr & 1) { // WFE
                        uint64_t pc;
                        HV_CHECK(hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc));
                        HV_CHECK(hv_vcpu_set_reg(vcpu->vcpu, HV_REG_PC, pc + 4));
                    } else {
                        handle_wfi(vcpu);
                    }
                } else {
                    uint64_t pc = 0;
                    hv_vcpu_get_reg(vcpu->vcpu, HV_REG_PC, &pc);
                    fprintf(stderr, "Unhandled exception EC=0x%x, ESR=0x%llx, PC=0x%llx, FAR=0x%llx\n",
                            ec, (unsigned long long)esr, (unsigned long long)pc,
                            (unsigned long long)vcpu->exit->exception.virtual_address);
                    exit(1);
                }
                break;
            }
            default:
                fprintf(stderr, "Unknown vCPU exit reason %u\n", vcpu->exit->reason);
                exit(1);
        }
    }

    hv_vcpu_destroy(vcpu->vcpu);
    return NULL;
}

// -----------------------------------------------------------------------------
// Kernel & Initrd Loader
// -----------------------------------------------------------------------------

static bool load_file(const char *path, uint8_t **out_data, size_t *out_size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return false; }
    size_t sz = st.st_size;
    uint8_t *b = malloc(sz);
    if (!b) { close(fd); return false; }
    if (read(fd, b, sz) != (ssize_t)sz) { free(b); close(fd); return false; }
    close(fd);
    *out_data = b;
    *out_size = sz;
    return true;
}

static bool load_kernel(const char *path, uint8_t **out_data, size_t *out_size, uint64_t *out_text_off, uint64_t *out_img_sz) {
    uint8_t *raw = NULL;
    size_t sz = 0;
    if (!load_file(path, &raw, &sz)) return false;

    // Check EFI zboot PE
    if (sz > 0x30 && raw[0] == 'M' && raw[1] == 'Z' && memcmp(raw + 4, "zimg", 4) == 0) {
        uint32_t p_off = *(uint32_t *)(raw + 8);
        uint32_t p_sz = *(uint32_t *)(raw + 12);
        const char *comp = (const char *)(raw + 0x18);
        if (strncmp(comp, "gzip", 4) != 0 || p_off + p_sz > sz) {
            free(raw);
            return false;
        }

        z_stream strm;
        memset(&strm, 0, sizeof(strm));
        strm.next_in = raw + p_off;
        strm.avail_in = p_sz;
        if (inflateInit2(&strm, 16 + MAX_WBITS) != Z_OK) {
            free(raw);
            return false;
        }

        size_t cap = 32 * 1024 * 1024;
        uint8_t *decomp = malloc(cap);
        strm.next_out = decomp;
        strm.avail_out = (uInt)cap;

        while (1) {
            int ret = inflate(&strm, Z_NO_FLUSH);
            if (ret == Z_STREAM_END) break;
            if (ret != Z_OK) {
                inflateEnd(&strm);
                free(decomp);
                free(raw);
                return false;
            }
            if (strm.avail_out == 0) {
                size_t old = cap;
                cap *= 2;
                decomp = realloc(decomp, cap);
                strm.next_out = decomp + old;
                strm.avail_out = (uInt)old;
            }
        }
        sz = strm.total_out;
        inflateEnd(&strm);
        free(raw);
        raw = decomp;
    }

    uint64_t text_off = 0;
    uint64_t img_sz = sz;
    if (sz >= 0x40 && memcmp(raw + 0x38, "ARMd", 4) == 0) {
        text_off = *(uint64_t *)(raw + 0x08);
        img_sz = *(uint64_t *)(raw + 0x10);
        if (img_sz == 0) img_sz = sz;
    }

    *out_data = raw;
    *out_size = sz;
    *out_text_off = text_off;
    *out_img_sz = img_sz;
    return true;
}

// -----------------------------------------------------------------------------
// Main & CLI
// -----------------------------------------------------------------------------

int main(int argc, char **argv) {
    const char *kernel_path = NULL;
    const char *initrd_path = NULL;
    const char *disk_path = NULL;
    bool disk_ro = false;
    const char *cmdline = "console=ttyAMA0 earlycon=pl011,0x09000000";
    uint64_t mem_mib = 1024;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--kernel") == 0 && i + 1 < argc) kernel_path = argv[++i];
        else if (strcmp(argv[i], "--initrd") == 0 && i + 1 < argc) initrd_path = argv[++i];
        else if (strcmp(argv[i], "--disk") == 0 && i + 1 < argc) disk_path = argv[++i];
        else if (strcmp(argv[i], "--readonly") == 0) disk_ro = true;
        else if (strcmp(argv[i], "--cmdline") == 0 && i + 1 < argc) cmdline = argv[++i];
        else if (strcmp(argv[i], "--mem") == 0 && i + 1 < argc) mem_mib = strtoull(argv[++i], NULL, 10);
        else if (strcmp(argv[i], "--cpus") == 0 && i + 1 < argc) g_num_cpus = (uint32_t)strtoul(argv[++i], NULL, 10);
    }

    if (!kernel_path) {
        fprintf(stderr, "Usage: %s --kernel PATH [--initrd PATH] [--disk PATH [--readonly]] [--cmdline STR] [--mem MiB] [--cpus N]\n", argv[0]);
        return 1;
    }
    if (g_num_cpus < 1 || g_num_cpus > MAX_CPUS) g_num_cpus = 2;
    if (!__builtin_available(macOS 15, *)) {
        fprintf(stderr, "oriel-hv needs macOS 15 or later (Hypervisor.framework GICv3).\n");
        return 1;
    }

    g_ram_size = (mem_mib * 1024 * 1024ULL + 0x3FFF) & ~0x3FFFULL;

    hv_vm_config_t vm_config = hv_vm_config_create();
    HV_CHECK(hv_vm_create(vm_config));
    HV_CHECK(hv_vm_allocate(&g_ram_ptr, g_ram_size, HV_ALLOCATE_DEFAULT));
    HV_CHECK(hv_vm_map(g_ram_ptr, g_ram_base, g_ram_size, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));

    // GIC Setup
    hv_gic_config_t gic_cfg = hv_gic_config_create();
    HV_CHECK(hv_gic_config_set_distributor_base(gic_cfg, GIC_DIST_BASE));
    HV_CHECK(hv_gic_config_set_redistributor_base(gic_cfg, GIC_REDIST_BASE));
    HV_CHECK(hv_gic_create(gic_cfg));

    size_t dist_size = 0, redist_reg_size = 0, redist_size = 0;
    size_t dist_align = 0, redist_align = 0;
    uint32_t spi_base = 32, spi_count = 0;
    HV_CHECK(hv_gic_get_distributor_size(&dist_size));
    HV_CHECK(hv_gic_get_redistributor_region_size(&redist_reg_size));
    HV_CHECK(hv_gic_get_redistributor_size(&redist_size));
    HV_CHECK(hv_gic_get_distributor_base_alignment(&dist_align));
    HV_CHECK(hv_gic_get_redistributor_base_alignment(&redist_align));
    HV_CHECK(hv_gic_get_spi_interrupt_range(&spi_base, &spi_count));

    // The redistributor region is sized for the framework's maximum vCPU count; keep it clear of the MMIO devices.
    if (GIC_REDIST_BASE % redist_align || GIC_DIST_BASE % dist_align ||
        GIC_REDIST_BASE + redist_reg_size > RAM_BASE ||
        (GIC_REDIST_BASE < VIRTIO_BASE + VIRTIO_SIZE && GIC_REDIST_BASE + redist_reg_size > UART_BASE)) {
        fprintf(stderr, "GIC layout conflict: redistributors 0x%llx + 0x%zx\n", GIC_REDIST_BASE, redist_reg_size);
        return 1;
    }

    uint32_t vtimer_intid = 27;
    hv_gic_get_intid(HV_GIC_INT_EL1_VIRTUAL_TIMER, &vtimer_intid);

    // Initialize Devices
    pthread_mutex_init(&g_uart.lock, NULL);
    g_uart.spi_id = spi_base + 1;
    g_uart.cr = 0x301;

    if (disk_path) {
        int dfd = open(disk_path, disk_ro ? O_RDONLY : O_RDWR);
        if (dfd >= 0) {
            struct stat dst;
            fstat(dfd, &dst);
            g_virtio.disk_fd = dfd;
            g_virtio.readonly = disk_ro;
            g_virtio.capacity_sectors = dst.st_size / 512;
            g_virtio.spi_id = spi_base + 2;
            pthread_mutex_init(&g_virtio.lock, NULL);
            g_has_disk = true;
        }
    }

    // Load Kernel
    uint8_t *kdata = NULL;
    size_t klen = 0;
    uint64_t text_off = 0, img_sz = 0;
    if (!load_kernel(kernel_path, &kdata, &klen, &text_off, &img_sz)) {
        fprintf(stderr, "Failed to load kernel: %s\n", kernel_path);
        return 1;
    }
    uint64_t kload_ipa = g_ram_base + text_off;
    memcpy((uint8_t *)g_ram_ptr + (kload_ipa - g_ram_base), kdata, klen);
    free(kdata);

    // Load Initrd
    uint64_t initrd_ipa = (kload_ipa + img_sz + 0x1FFFFFULL) & ~0x1FFFFFULL;
    size_t initrd_sz = 0;
    if (initrd_path) {
        uint8_t *idata = NULL;
        if (!load_file(initrd_path, &idata, &initrd_sz)) {
            fprintf(stderr, "Failed to load initrd: %s\n", initrd_path);
            return 1;
        }
        memcpy((uint8_t *)g_ram_ptr + (initrd_ipa - g_ram_base), idata, initrd_sz);
        free(idata);
    }

    // Generate FDT
    uint64_t dtb_ipa = g_ram_base + g_ram_size - 0x200000ULL;
    fdt_t fdt;
    fdt_init(&fdt);
    fdt_begin_node(&fdt, "");
    fdt_prop_u32(&fdt, "#address-cells", 2);
    fdt_prop_u32(&fdt, "#size-cells", 2);
    fdt_prop_str(&fdt, "compatible", "linux,dummy-virt");
    fdt_prop_u32(&fdt, "interrupt-parent", 1);

    // /cpus
    fdt_begin_node(&fdt, "cpus");
    fdt_prop_u32(&fdt, "#address-cells", 1);
    fdt_prop_u32(&fdt, "#size-cells", 0);
    for (uint32_t i = 0; i < g_num_cpus; i++) {
        char cname[32];
        snprintf(cname, sizeof(cname), "cpu@%u", i);
        fdt_begin_node(&fdt, cname);
        fdt_prop_str(&fdt, "device_type", "cpu");
        fdt_prop_str(&fdt, "compatible", "arm,arm-v8");
        fdt_prop_u32(&fdt, "reg", i);
        fdt_prop_str(&fdt, "enable-method", "psci");
        fdt_end_node(&fdt);
    }
    fdt_end_node(&fdt);

    // /psci
    fdt_begin_node(&fdt, "psci");
    fdt_prop(&fdt, "compatible", "arm,psci-1.0\0arm,psci-0.2\0", 26);
    fdt_prop_str(&fdt, "method", "hvc");
    fdt_end_node(&fdt);

    // /intc
    fdt_begin_node(&fdt, "intc@8000000");
    fdt_prop_str(&fdt, "compatible", "arm,gic-v3");
    fdt_prop_u32(&fdt, "#interrupt-cells", 3);
    fdt_prop_u32(&fdt, "#address-cells", 2);
    fdt_prop_u32(&fdt, "#size-cells", 2);
    fdt_prop(&fdt, "interrupt-controller", NULL, 0);
    uint32_t gic_reg[8] = {
        htonl(0), htonl(GIC_DIST_BASE), htonl(0), htonl((uint32_t)dist_size),
        htonl(0), htonl(GIC_REDIST_BASE), htonl(0), htonl((uint32_t)redist_reg_size)
    };
    fdt_prop(&fdt, "reg", gic_reg, sizeof(gic_reg));
    fdt_prop_u32(&fdt, "phandle", 1);
    fdt_end_node(&fdt);

    // /timer
    fdt_begin_node(&fdt, "timer");
    fdt_prop_str(&fdt, "compatible", "arm,armv8-timer");
    uint32_t timer_irqs[12] = {
        htonl(1), htonl(13), htonl(4),
        htonl(1), htonl(14), htonl(4),
        htonl(1), htonl(11), htonl(4),
        htonl(1), htonl(10), htonl(4)
    };
    fdt_prop(&fdt, "interrupts", timer_irqs, sizeof(timer_irqs));
    fdt_prop(&fdt, "always-on", NULL, 0);
    fdt_end_node(&fdt);

    // /clk24mhz
    fdt_begin_node(&fdt, "apb-pclk");
    fdt_prop_str(&fdt, "compatible", "fixed-clock");
    fdt_prop_u32(&fdt, "#clock-cells", 0);
    fdt_prop_u32(&fdt, "clock-frequency", 24000000);
    fdt_prop_str(&fdt, "clock-output-names", "clk24mhz");
    fdt_prop_u32(&fdt, "phandle", 2);
    fdt_end_node(&fdt);

    // /pl011
    fdt_begin_node(&fdt, "pl011@9000000");
    fdt_prop(&fdt, "compatible", "arm,pl011\0arm,primecell\0", 24);
    uint32_t uart_reg[4] = { htonl(0), htonl(UART_BASE), htonl(0), htonl(UART_SIZE) };
    fdt_prop(&fdt, "reg", uart_reg, sizeof(uart_reg));
    uint32_t uart_irq[3] = { htonl(0), htonl(1), htonl(4) }; // SPI index 1
    fdt_prop(&fdt, "interrupts", uart_irq, sizeof(uart_irq));
    fdt_prop_u32(&fdt, "arm,primecell-periphid", 0x00241011);
    uint32_t clk_refs[2] = { htonl(2), htonl(2) };
    fdt_prop(&fdt, "clocks", clk_refs, sizeof(clk_refs));
    fdt_prop(&fdt, "clock-names", "uartclk\0apb_pclk\0", 17);
    fdt_end_node(&fdt);

    // /virtio_mmio
    if (g_has_disk) {
        fdt_begin_node(&fdt, "virtio_mmio@a000000");
        fdt_prop_str(&fdt, "compatible", "virtio,mmio");
        uint32_t v_reg[4] = { htonl(0), htonl(VIRTIO_BASE), htonl(0), htonl(VIRTIO_SIZE) };
        fdt_prop(&fdt, "reg", v_reg, sizeof(v_reg));
        uint32_t v_irq[3] = { htonl(0), htonl(2), htonl(4) }; // SPI index 2
        fdt_prop(&fdt, "interrupts", v_irq, sizeof(v_irq));
        fdt_end_node(&fdt);
    }

    // /memory
    fdt_begin_node(&fdt, "memory@40000000");
    fdt_prop_str(&fdt, "device_type", "memory");
    uint32_t mem_reg[4] = { htonl(0), htonl(g_ram_base), htonl(g_ram_size >> 32), htonl(g_ram_size & 0xFFFFFFFF) };
    fdt_prop(&fdt, "reg", mem_reg, sizeof(mem_reg));
    fdt_end_node(&fdt);

    // /chosen
    fdt_begin_node(&fdt, "chosen");
    fdt_prop_str(&fdt, "bootargs", cmdline);
    fdt_prop_str(&fdt, "stdout-path", "/pl011@9000000");
    if (initrd_path && initrd_sz > 0) {
        fdt_prop_u64(&fdt, "linux,initrd-start", initrd_ipa);
        fdt_prop_u64(&fdt, "linux,initrd-end", initrd_ipa + initrd_sz);
    }
    fdt_end_node(&fdt);

    fdt_end_node(&fdt);
    size_t dtb_sz = 0;
    void *dtb_blob = fdt_finish(&fdt, &dtb_sz);
    memcpy((uint8_t *)g_ram_ptr + (dtb_ipa - g_ram_base), dtb_blob, dtb_sz);
    free(dtb_blob);

    // Banner
    fprintf(stderr, "=== oriel-hv ===\n");
    fprintf(stderr, "RAM:     0x%llx - 0x%llx (%llu MiB)\n", (unsigned long long)g_ram_base, (unsigned long long)(g_ram_base + g_ram_size), (unsigned long long)mem_mib);
    fprintf(stderr, "Kernel:  0x%llx (size 0x%llx)\n", (unsigned long long)kload_ipa, (unsigned long long)img_sz);
    if (initrd_path) fprintf(stderr, "Initrd:  0x%llx (size 0x%zx)\n", (unsigned long long)initrd_ipa, initrd_sz);
    fprintf(stderr, "DTB:     0x%llx (size 0x%zx)\n", (unsigned long long)dtb_ipa, dtb_sz);
    fprintf(stderr, "GICv3:   Dist 0x%08llx, Redist 0x%08llx\n", (unsigned long long)GIC_DIST_BASE, (unsigned long long)GIC_REDIST_BASE);
    fprintf(stderr, "Redist region size 0x%zx, SPI base %u, vtimer intid %u\n", redist_reg_size, spi_base, vtimer_intid);
    fprintf(stderr, "vCPUs:   %u\n", g_num_cpus);

    g_boot_pc = kload_ipa;
    g_boot_dtb = dtb_ipa;

    // Spawn vCPUs
    for (uint32_t i = 0; i < g_num_cpus; i++) {
        g_vcpus[i].id = i;
        pthread_mutex_init(&g_vcpus[i].lock, NULL);
        pthread_cond_init(&g_vcpus[i].cond, NULL);
        g_vcpus[i].created = false;
        g_vcpus[i].running = (i == 0);
        pthread_create(&g_vcpus[i].thread, NULL, vcpu_thread_func, &g_vcpus[i]);
    }

    // Wait for all vCPUs to be created before running
    for (uint32_t i = 0; i < g_num_cpus; i++) {
        pthread_mutex_lock(&g_vcpus[i].lock);
        while (!g_vcpus[i].created) {
            pthread_cond_wait(&g_vcpus[i].cond, &g_vcpus[i].lock);
        }
        pthread_mutex_unlock(&g_vcpus[i].lock);
    }

    setup_terminal();
    pthread_t stdin_th;
    pthread_create(&stdin_th, NULL, stdin_thread_func, NULL);

    for (uint32_t i = 0; i < g_num_cpus; i++) {
        pthread_join(g_vcpus[i].thread, NULL);
    }

    g_shutdown = true;
    restore_terminal();
    return 0;
}
