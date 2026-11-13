/*
 * MicroCommander jádro – C ABI pro tenké Swift/AppKit UI.
 *
 * Handle VFS lze používat z více vláken zároveň (UI vypisuje panel na pozadí
 * i během běžící operace) – jádro si přístup ke sdílenému stavu zamyká samo,
 * příkazy nad jedním FTP/SFTP spojením se serializují. Uvolnit handle
 * (sal_vfs_close) se smí až poté, co ho žádné vlákno nepoužívá.
 *
 * Konvence chyb: návratový kód 0 = úspěch (SAL_OK), 1 = zrušeno uživatelem,
 * záporné hodnoty = chyba. Text chyby se zapisuje do bufferu `err`.
 *
 * Cesty VFS jsou vždy s lomítky, absolutní od kořene daného VFS ("/").
 */

#ifndef MICROCOMMANDER_H
#define MICROCOMMANDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Chybové kódy (odpovídají SalError::code v jádře). */
#define SAL_OK 0
#define SAL_ERR_CANCELLED 1
#define SAL_ERR_GENERIC (-1)
#define SAL_ERR_NOT_FOUND (-2)
#define SAL_ERR_EXISTS (-3)
#define SAL_ERR_NOT_EMPTY (-4)
#define SAL_ERR_PERMISSION (-5)
#define SAL_ERR_CREATE_DIR (-6)
#define SAL_ERR_PASSWORD_REQUIRED (-7) /* šifrovaná položka archivu, chybí heslo */
#define SAL_ERR_BAD_PASSWORD (-8)      /* zadané heslo k archivu je chybné */

/* Druhy souborových systémů. */
#define SAL_VFS_LOCAL 1
#define SAL_VFS_ZIP 2
#define SAL_VFS_TAR 3
#define SAL_VFS_FTP 4
#define SAL_VFS_SFTP 5

/* Příznaky položky ve výpisu. */
#define SAL_FLAG_DIR 1
#define SAL_FLAG_LINK 2
#define SAL_FLAG_HIDDEN 4
#define SAL_FLAG_READONLY 8
#define SAL_FLAG_ENCRYPTED 16 /* zašifrovaná položka archivu */

/* Šifrování při vytváření ZIP (sal_pack_zip_ex). */
#define SAL_ZIP_ENC_NONE 0
#define SAL_ZIP_ENC_AES256 1    /* WinZip AES-256 (AE-2), doporučeno */
#define SAL_ZIP_ENC_ZIPCRYPTO 2 /* tradiční ZipCrypto – slabé, jen pro kompatibilitu */

/* Režim řešení existujícího cíle. */
#define SAL_OVERWRITE_ASK 0
#define SAL_OVERWRITE_OVERWRITE 1
#define SAL_OVERWRITE_SKIP 2

/* Neprůhledný handle na otevřený souborový systém. Definice je záměrně
 * jen formální (obsah spravuje jádro), díky ní Swift importuje konkrétní
 * UnsafeMutablePointer<SalVfs> místo prázdného typu. */
typedef struct SalVfs {
    int32_t _opaque;
} SalVfs;

/* Jedna položka výpisu adresáře. Jméno je UTF-8, uvolní sal_free_items. */
typedef struct {
    char *name;
    uint64_t size;
    int64_t mtime; /* unixové sekundy UTC */
    uint32_t flags;
} SalItem;

/* Hlášení průběhu operace; návrat 0 zruší operaci, nenulová pokračuje. Může být NULL. */
typedef struct {
    int32_t (*on_progress)(void *user, uint64_t done, uint64_t total);
    void *user;
} SalProgress;

/* Zpětné volání hledání: nalezená položka na cestě (VFS cesta včetně jména). */
typedef void (*SalFoundFn)(void *user, const char *path, uint64_t size, int64_t mtime,
                           uint32_t flags);

/* Verze jádra (statický řetězec, neuvolňovat). */
const char *sal_version(void);

/* Otevření lokálního VFS; root NULL nebo "" = celý disk ("/"). */
SalVfs *sal_open_local(const char *root);

/* Otevření archivu jako VFS (jen pro čtení). Vrací NULL při selhání. */
SalVfs *sal_open_zip(const char *archive_path);
SalVfs *sal_open_tar(const char *archive_path); /* .tar i .tar.gz */

/* Připojení FTP / SFTP. Vrací NULL při selhání (text v err). */
SalVfs *sal_connect_ftp(const char *host, uint16_t port, const char *user,
                        const char *password, double timeout_sec, char *err, size_t err_len);
SalVfs *sal_connect_sftp(const char *host, uint16_t port, const char *user,
                         const char *password, double timeout_sec, char *err, size_t err_len);

/* Připojení SFTP soukromým klíčem ze souboru (OpenSSH/PEM: ed25519, ECDSA, RSA);
 * veřejný klíč se odvodí ze soukromého (soubor .pub není potřeba);
 * passphrase NULL nebo "" = klíč bez hesla. */
SalVfs *sal_connect_sftp_key(const char *host, uint16_t port, const char *user,
                             const char *private_key_path, const char *passphrase,
                             double timeout_sec, char *err, size_t err_len);

/* Je soubor se soukromým klíčem chráněný heslem? 1 = ano, 0 = ne, -1 = nelze přečíst. */
int32_t sal_ssh_key_encrypted(const char *private_key_path);

/* Připojení SFTP klíči ze ssh-agenta (zkouší všechny načtené identity). */
SalVfs *sal_connect_sftp_agent(const char *host, uint16_t port, const char *user,
                               double timeout_sec, char *err, size_t err_len);

/* Metadata otevřeného VFS. */
int32_t sal_vfs_kind(SalVfs *vfs);
/* Popisek panelu; zapisuje do out (vždy NUL-ukončený). */
int32_t sal_vfs_label(SalVfs *vfs, char *out, size_t out_len);
int32_t sal_vfs_writable(SalVfs *vfs);
void sal_vfs_close(SalVfs *vfs);

/* Výpis adresáře. Out_items alokuje jádro, uvolní sal_free_items. */
int32_t sal_vfs_list(SalVfs *vfs, const char *path, SalItem **out_items, size_t *out_count,
                     char *err, size_t err_len);
void sal_free_items(SalItem *items, size_t count);

/* Existence a druh položky. */
int32_t sal_vfs_is_dir(SalVfs *vfs, const char *path, int32_t *out, char *err, size_t err_len);
int32_t sal_vfs_exists(SalVfs *vfs, const char *path, int32_t *out, char *err, size_t err_len);

/* Volné místo v bajtech; -1 = nelze zjistit. */
int64_t sal_vfs_free_space(SalVfs *vfs, const char *path);

/* Kopírování / přesun vybraných jmen z adresáře do adresáře (rekurzivně).
 * Existující adresáře se slučují, existující soubory řeší `overwrite`
 * (SAL_OVERWRITE_ASK = skončit kódem SAL_ERR_EXISTS). Přenos do téhož adresáře
 * nebo adresáře do sebe sama je chyba. Při přesunu zůstávají ve zdroji
 * položky přeskočené přes SAL_OVERWRITE_SKIP. */
int32_t sal_copy(SalVfs *src, const char *src_dir, const char *const *names, size_t count,
                 SalVfs *dst, const char *dst_dir, int32_t overwrite,
                 const SalProgress *progress, char *err, size_t err_len);
int32_t sal_move(SalVfs *src, const char *src_dir, const char *const *names, size_t count,
                 SalVfs *dst, const char *dst_dir, int32_t overwrite,
                 const SalProgress *progress, char *err, size_t err_len);

/* Mazání vybraných položek (adresáře rekurzivně). */
int32_t sal_delete(SalVfs *vfs, const char *dir, const char *const *names, size_t count,
                   const SalProgress *progress, char *err, size_t err_len);

/* Vytvoření adresáře (nevnořený). */
int32_t sal_mkdir(SalVfs *vfs, const char *path, char *err, size_t err_len);

/* Přejmenování položky v adresáři (jen jméno, ne cestu). Existující jinou
 * položku téhož jména nenahradí – vrátí SAL_ERR_EXISTS. */
int32_t sal_rename(SalVfs *vfs, const char *dir, const char *old_name, const char *new_name,
                   char *err, size_t err_len);

/* Hledání podle masky (DOS zástupné znaky, skupiny ; a vyloučení |).
 * Nalezené položky hlásí `found`; progress hlásí prohledané položky (total=0). */
int32_t sal_find(SalVfs *vfs, const char *root, const char *mask, int32_t include_dirs,
                 const SalProgress *progress, SalFoundFn found, void *found_user,
                 char *err, size_t err_len);

/* Příznaky sal_find_ex (odpovídají volbám dialogu Find Salamandera). */
#define SAL_FIND_SUBDIRS 1        /* Včetně podadresářů */
#define SAL_FIND_INCLUDE_DIRS 2   /* hlásit i adresáře odpovídající masce */
#define SAL_FIND_CONTENT 4        /* Hledat v souboru (content = hledaný vzor) */
#define SAL_FIND_CASE 8           /* Rozlišovat malá a velká písmena */
#define SAL_FIND_WHOLE_WORDS 16   /* Celá slova */
#define SAL_FIND_REGEX 32         /* Regulární výraz (vyhodnocuje se po řádcích) */
#define SAL_FIND_HEX 64           /* content jsou syrové bajty (Šestnáctkový režim) */
#define SAL_FIND_NAME_CONTAINS 128 /* maska bez * ? . hledá jména, která ji obsahují */

/* Hlášení právě prohledávaného adresáře (stavový řádek dialogu). */
typedef void (*SalFindDirFn)(void *user, const char *path);

/* Hledání s volbami (SAL_FIND_*). Nečitelné podadresáře a soubory se přeskočí,
 * jejich počet vrátí `errors` (smí být NULL). `found` i `dir_cb` dostávají `user`. */
int32_t sal_find_ex(SalVfs *vfs, const char *root, const char *mask, uint32_t flags,
                    const uint8_t *content, size_t content_len, const SalProgress *progress,
                    SalFoundFn found, SalFindDirFn dir_cb, void *user, uint64_t *errors,
                    char *err, size_t err_len);

/* Detekce archivu podle obsahu souboru: 0 = není, SAL_VFS_ZIP, SAL_VFS_TAR
 * (TAR i TAR.GZ; samostatný gzip bez TAR uvnitř archiv není). */
int32_t sal_probe_archive(const char *path);

/* Vytvoření ZIP archivu z vybraných položek libovolného VFS. */
int32_t sal_pack_zip(SalVfs *src, const char *src_dir, const char *const *names, size_t count,
                     const char *dest_zip, const SalProgress *progress, char *err, size_t err_len);

/* Vytvoření ZIP archivu se šifrováním (SAL_ZIP_ENC_*); password se u NONE ignoruje. */
int32_t sal_pack_zip_ex(SalVfs *src, const char *src_dir, const char *const *names, size_t count,
                        const char *dest_zip, int32_t encryption, const char *password,
                        const SalProgress *progress, char *err, size_t err_len);

/* Heslo pro čtení šifrovaných položek archivu (NULL = zapomenout).
 * Vrací 1, pokud VFS hesla podporuje (ZIP), jinak 0. */
int32_t sal_vfs_set_password(SalVfs *vfs, const char *password);

/* Obsahuje VFS šifrované položky? 1 = ano, 0 = ne. */
int32_t sal_vfs_has_encrypted(SalVfs *vfs);

#ifdef __cplusplus
}
#endif

#endif /* MICROCOMMANDER_H */
