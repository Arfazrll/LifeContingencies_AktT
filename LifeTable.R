suppressWarnings({
  ensure_pkg <- function(pkg) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      install.packages(pkg, repos = "https://cloud.r-project.org")
    }
    suppressPackageStartupMessages(library(pkg, character.only = TRUE))
  }
  ensure_pkg("lifecontingencies")
  ensure_pkg("readxl")
})

read_num <- function(prompt, default = NULL, min = -Inf, max = Inf, integer_only = FALSE) {
  repeat {
    cat(if (!is.null(default)) sprintf("%s [%s]: ", prompt, as.character(default)) else paste0(prompt, ": "))
    ans <- trimws(readline())
    if (ans == "" && !is.null(default)) return(default)
    val <- suppressWarnings(as.numeric(ans))
    if (!is.na(val) && is.finite(val) && val >= min && val <= max) {
      if (integer_only) val <- as.integer(round(val))
      return(val)
    }
    cat(">> Input tidak valid. Harus numerik",
        if (is.finite(min) || is.finite(max)) sprintf(" di rentang [%s..%s]", min, max) else "",
        if (integer_only) " dan bilangan bulat" else "", ".\n", sep = "")
  }
}

read_choice <- function(prompt, choices, default = NULL) {
  ch_str <- paste(choices, collapse = "/")
  repeat {
    cat(if (!is.null(default)) sprintf("%s (%s) [%s]: ", prompt, ch_str, default) else sprintf("%s (%s): ", prompt, ch_str))
    ans <- tolower(trimws(readline()))
    if (ans == "" && !is.null(default)) return(default)
    if (ans %in% tolower(choices)) return(ans)
    cat(">> Pilihan tidak valid. Gunakan: ", ch_str, "\n", sep = "")
  }
}

read_path <- function(prompt) {
  repeat {
    cat(prompt, ": ")
    p <- trimws(readline())
    if (file.exists(p)) return(p)
    cat(">> File tidak ditemukan. Coba lagi.\n")
  }
}

load_actuarial_table_from_excel <- function(path, interest = 0.05, name = "ImportedTable") {
  df <- tryCatch(readxl::read_excel(path), error = function(e) e)
  if (inherits(df, "error")) stop("File tidak dapat dibaca sebagai Excel.")
  nms <- tolower(names(df))
  if (!all(c("x", "lx") %in% nms)) stop("File harus memiliki kolom 'x' dan 'lx'.")
  # Normalisasi nama kolom
  names(df) <- nms
  if (any(!is.finite(df$x)) || any(!is.finite(df$lx))) stop("Kolom x/lx harus numerik dan finite.")
  if (any(df$lx < 0)) stop("Nilai lx tidak boleh negatif.")
  if (length(unique(df$x)) != nrow(df)) stop("Kolom x (umur) harus unik per baris.")
  df <- df[order(df$x), ]
  if (any(diff(df$lx) > 1e-8)) {
    cat(">> Peringatan: lx tampak tidak non-increasing. Pastikan tabel mortalita valid.\n")
  }
  lifecontingencies::new("actuarialtable", interest = interest, x = df$x, lx = df$lx, name = name)
}

build_demo_table <- function(interest = 0.05, omega = 120L, name = "DemoGM") {
  x <- 0:omega
  A <- 0.0005; B <- 0.00003; c <- 1.09
  # Kekuatan mortalita (mu_x ~ A + B*c^x), approksimasi qx ~ 1 - exp(-mu_x)
  mu <- A + B * (c ^ x)
  qx <- 1 - exp(-mu)
  qx[qx > 0.999] <- 0.999
  lx <- numeric(length(x))
  lx[1] <- 100000
  for (i in 1:(length(x) - 1)) {
    lx[i + 1] <- lx[i] * (1 - qx[i])
  }
  lifecontingencies::new("actuarialtable", interest = interest, x = x, lx = lx, name = name)
}

check_age_range <- function(tbl, x, n) {
  minx <- min(tbl@x); maxx <- max(tbl@x)
  if (x < minx) stop(sprintf("Umur x terlalu kecil (min %s).", minx))
  if ((x + n) > maxx) stop(sprintf("x + n melampaui tabel (max x = %s). Kurangi n atau gunakan tabel lebih panjang.", maxx))
  invisible(TRUE)
}

hitung_premi_bruto <- function(
    tbl, x, n, n1, up,
    i = tbl@interest, 
    m = 1L,
    payment = c("due", "immediate"),
    w1 = 0.75,
    def_k1 = 1,        # deferment untuk PV1
    def_k2 = 0,        # deferment untuk PV2
    m1 = m, m2 = m,    # frekuensi untuk PV1/PV2
    load_fixed = 100000,
    load_rate_up = 0.001,     # % x UP
    load_rate_up2 = 0.0015    # % x UP (kedua)
) {
  payment <- match.arg(payment)
  if (n <= 0) stop("n harus > 0.")
  if (n1 < 0 || n1 > n) stop("n1 harus di rentang [0, n].")
  if (up <= 0) stop("UP harus > 0.")
  check_age_range(tbl, x, n)

  # Annuity-due/immediate
  ax <- lifecontingencies::axn(tbl, x = x, n = n, i = i, m = m, payment = payment)

  # PV1: term insurance n1 dengan deferment def_k1, dibobot w1
  PV1 <- if (n1 > 0) lifecontingencies::Axn(tbl, x = x, n = n1, i = i, k = def_k1, m = m1) * w1 else 0
  # PV2: term insurance sisa (n - n1) dengan deferment def_k2
  PV2 <- if ((n - n1) > 0) lifecontingencies::Axn(tbl, x = x, n = (n - n1), i = i, k = def_k2, m = m2) else 0
  # PV3: pure endowment di akhir n
  PV3 <- lifecontingencies::Exn(tbl, x = x, n = n, i = i)

  Ax_total <- PV1 + PV2 + PV3

  # Premi bersih
  Px <- (Ax_total / ax) * up

  # Loading (tetap + %UP + %UP kedua)
  Loadx <- load_fixed + load_rate_up * up + load_rate_up2 * up

  # Premi bruto
  Pbrutox <- Px + Loadx

  list(
    parameters = list(x = x, n = n, n1 = n1, up = up, i = i, m = m,
                      payment = payment, w1 = w1, def_k1 = def_k1, def_k2 = def_k2,
                      m1 = m1, m2 = m2,
                      load_fixed = load_fixed, load_rate_up = load_rate_up, load_rate_up2 = load_rate_up2),
    components = list(PV1 = PV1, PV2 = PV2, PV3 = PV3, Ax_total = Ax_total, ax = ax),
    results = list(Px = Px, Loadx = Loadx, Pbrutox = Pbrutox)
  )
}

simpan_hasil_txt <- function(out, file_name) {
  lines <- c(
    "# Hasil Perhitungan Premi Bruto",
    sprintf("Ax_total: %.6f", out$components$Ax_total),
    sprintf("  - PV1: %.6f", out$components$PV1),
    sprintf("  - PV2: %.6f", out$components$PV2),
    sprintf("  - PV3: %.6f", out$components$PV3),
    sprintf("ax: %.6f", out$components$ax),
    sprintf("Px (Net): %.2f", out$results$Px),
    sprintf("Loadx: %.2f", out$results$Loadx),
    sprintf("Pbrutox: %.2f", out$results$Pbrutox)
  )
  writeLines(lines, file_name)
  cat(">> Hasil disimpan (TXT):", normalizePath(file_name), "\n")
}

simpan_hasil_csv <- function(out, file_name) {
  df <- data.frame(
    Ax_total = out$components$Ax_total,
    PV1 = out$components$PV1,
    PV2 = out$components$PV2,
    PV3 = out$components$PV3,
    ax = out$components$ax,
    Px = out$results$Px,
    Loadx = out$results$Loadx,
    Pbrutox = out$results$Pbrutox,
    x = out$parameters$x,
    n = out$parameters$n,
    n1 = out$parameters$n1,
    up = out$parameters$up,
    i = out$parameters$i,
    m = out$parameters$m,
    payment = out$parameters$payment,
    w1 = out$parameters$w1,
    def_k1 = out$parameters$def_k1,
    def_k2 = out$parameters$def_k2,
    m1 = out$parameters$m1,
    m2 = out$parameters$m2,
    load_fixed = out$parameters$load_fixed,
    load_rate_up = out$parameters$load_rate_up,
    load_rate_up2 = out$parameters$load_rate_up2,
    stringsAsFactors = FALSE
  )
  utils::write.csv(df, file_name, row.names = FALSE)
  cat(">> Hasil disimpan (CSV):", normalizePath(file_name), "\n")
}

# ---------- UI Interaktif ----------
print_banner <- function() {
  cat("\n============================================\n")
  cat("  Program Perhitungan Premi Bruto (Aktuaria)\n")
  cat("============================================\n\n")
}

show_params <- function(P) {
  cat(">> Parameter saat ini:\n")
  cat(sprintf("   x=%d, n=%d, n1=%d, UP=%.0f\n", P$x, P$n, P$n1, P$up))
  cat(sprintf("   i=%.4f, m=%d, payment=%s\n", P$i, P$m, P$payment))
  cat(sprintf("   w1=%.4f, def_k1=%d, def_k2=%d, m1=%d, m2=%d\n", P$w1, P$def_k1, P$def_k2, P$m1, P$m2))
  cat(sprintf("   loading: fixed=%.0f, rate_up=%.4f, rate_up2=%.4f\n",
              P$load_fixed, P$load_rate_up, P$load_rate_up2))
}

modify_params <- function(P, tbl) {
  cat("\n--- Ubah Parameter ---\n(Enter untuk mempertahankan nilai saat ini)\n")
  P$x  <- read_num("Umur x", default = P$x, min = min(tbl@x), max = max(tbl@x), integer_only = TRUE)
  P$n  <- read_num("Durasi n (tahun)", default = P$n, min = 1, max = (max(tbl@x) - P$x), integer_only = TRUE)
  P$n1 <- read_num("Durasi n1 (PV1)", default = P$n1, min = 0, max = P$n, integer_only = TRUE)
  P$up <- read_num("UP (uang pertanggungan)", default = P$up, min = 1)
  P$i  <- read_num("Suku bunga i (desimal)", default = P$i, min = 0, max = 1)
  P$m  <- read_num("Frekuensi premi m (1=annual, 12=bulanan, dll.)", default = P$m, min = 1, max = 365, integer_only = TRUE)
  P$payment <- read_choice("Timing pembayaran premi", c("immediate", "due"), default = P$payment)
  P$w1 <- read_num("Bobot PV1 (w1)", default = P$w1, min = 0, max = 10)
  P$def_k1 <- read_num("Deferment PV1 (k1, tahun)", default = P$def_k1, min = 0, max = 200, integer_only = TRUE)
  P$def_k2 <- read_num("Deferment PV2 (k2, tahun)", default = P$def_k2, min = 0, max = 200, integer_only = TRUE)
  P$m1 <- read_num("Frekuensi PV1 (m1)", default = P$m1, min = 1, max = 365, integer_only = TRUE)
  P$m2 <- read_num("Frekuensi PV2 (m2)", default = P$m2, min = 1, max = 365, integer_only = TRUE)
  P$load_fixed <- read_num("Loading tetap (fixed)", default = P$load_fixed, min = 0)
  P$load_rate_up <- read_num("Loading % x UP (rate_up)", default = P$load_rate_up, min = 0, max = 1)
  P$load_rate_up2 <- read_num("Loading % x UP (rate_up2)", default = P$load_rate_up2, min = 0, max = 1)
  P
}

run_calculation <- function(tbl, P) {
  out <- tryCatch({
    hitung_premi_bruto(
      tbl = tbl, x = P$x, n = P$n, n1 = P$n1, up = P$up,
      i = P$i, m = P$m, payment = P$payment,
      w1 = P$w1, def_k1 = P$def_k1, def_k2 = P$def_k2,
      m1 = P$m1, m2 = P$m2,
      load_fixed = P$load_fixed, load_rate_up = P$load_rate_up, load_rate_up2 = P$load_rate_up2
    )
  }, error = function(e) e)
  if (inherits(out, "error")) {
    cat("!! Error perhitungan:", out$message, "\n")
    return(NULL)
  }
  cat("\n=== Hasil ===\n")
  cat(sprintf("Ax_total = %.6f (PV1=%.6f, PV2=%.6f, PV3=%.6f)\n",
              out$components$Ax_total, out$components$PV1, out$components$PV2, out$components$PV3))
  cat(sprintf("ax = %.6f\n", out$components$ax))
  cat(sprintf("Px (Premi Bersih) = %.2f\n", out$results$Px))
  cat(sprintf("Loadx (Loading)    = %.2f\n", out$results$Loadx))
  cat(sprintf("Pbrutox (Bruto)    = %.2f\n\n", out$results$Pbrutox))
  out
}

export_flow <- function(out) {
  repeat {
    act <- read_choice("Simpan hasil? (y/n)", c("y", "n"), default = "n")
    if (act == "n") return(invisible(NULL))
    fmt <- read_choice("Format simpan", c("txt", "csv"), default = "txt")
    cat("Nama file (mis. hasil.txt / hasil.csv): ")
    fname <- trimws(readline())
    if (fname == "") {
      cat(">> Nama file tidak boleh kosong.\n")
      next
    }
    if (tolower(tools::file_ext(fname)) != fmt) {
      fname <- paste0(fname, ".", fmt)
    }
    if (fmt == "txt") simpan_hasil_txt(out, fname) else simpan_hasil_csv(out, fname)
    return(invisible(NULL))
  }
}

main <- function() {
  print_banner()
  cat("Pilih sumber tabel mortalita:\n")
  cat("  1) Muat dari Excel (kolom: x, lx)\n")
  cat("  2) Pakai tabel demo (Gompertz-Makeham sintetis)\n")
  src <- read_choice("Sumber", c("1", "2"), default = "2")

  if (src == "1") {
    path <- read_path("Masukkan path file Excel")
    i0 <- read_num("Suku bunga awal i (desimal)", default = 0.05, min = 0, max = 1)
    tbl <- tryCatch(load_actuarial_table_from_excel(path, interest = i0, name = "ImportedTable"),
                    error = function(e) { cat("!! Error:", e$message, "\n"); return(NULL) })
    if (is.null(tbl)) return(invisible(NULL))
  } else {
    i0 <- read_num("Suku bunga awal i (desimal)", default = 0.05, min = 0, max = 1)
    tbl <- build_demo_table(interest = i0, omega = 120L)
  }

  # Parameter default 
  P <- list(
    x = 30L, n = 20L, n1 = 5L, up = 100000000, # 100 juta
    i = tbl@interest, m = 1L, payment = "due",
    w1 = 0.75, def_k1 = 1L, def_k2 = 0L, m1 = 1L, m2 = 5L,
    load_fixed = 100000, load_rate_up = 0.001, load_rate_up2 = 0.0015
  )

  repeat {
    show_params(P)
    cat("\nMenu:\n")
    cat("  1) Hitung premi (pakai parameter saat ini)\n")
    cat("  2) Ubah parameter\n")
    cat("  3) Ganti sumber tabel (Excel/Demo)\n")
    cat("  4) Keluar\n")
    act <- read_choice("Pilih", c("1", "2", "3", "4"), default = "1")

    if (act == "1") {
      out <- run_calculation(tbl, P)
      if (!is.null(out)) export_flow(out)
    } else if (act == "2") {
      P <- modify_params(P, tbl)
      # Sinkronkan suku bunga tabel jika diubah user
      if (abs(tbl@interest - P$i) > 1e-12) {
        tbl@interest <- P$i
      }
    } else if (act == "3") {
      src <- read_choice("Sumber baru (1=Excel, 2=Demo)", c("1", "2"), default = "2")
      if (src == "1") {
        path <- read_path("Masukkan path file Excel")
        i0 <- read_num("Suku bunga i untuk tabel ini", default = P$i, min = 0, max = 1)
        tmp <- tryCatch(load_actuarial_table_from_excel(path, interest = i0, name = "ImportedTable"),
                        error = function(e) { cat("!! Error:", e$message, "\n"); return(NULL) })
        if (!is.null(tmp)) {
          tbl <- tmp
          P$i <- tbl@interest
        }
      } else {
        i0 <- read_num("Suku bunga i untuk tabel demo", default = P$i, min = 0, max = 1)
        tbl <- build_demo_table(interest = i0, omega = 120L)
        P$i <- tbl@interest
      }
    } else if (act == "4") {
      cat("Selesai.\n")
      break
    }
  }
}

if (sys.nframe() == 0) {
  tryCatch(main(), error = function(e) {
    cat("!! Terjadi error fatal:", e$message, "\n")
  })
}
