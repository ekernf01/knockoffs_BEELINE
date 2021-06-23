setwd("~/Desktop/jhu/research/projects/Beeline")
library(magrittr)
library(ggplot2)

grabResults = function(pattern, 
                       reader = read.csv,
                       # base_dir = "outputs/Synthetic_with_protein_and_velocity", 
                       # To plot an older result:
                       base_dir = "../knockoffs/beeline freezes/outputs 2021-06-22 2/Synthetic_with_protein",
                       ...){
  x = list.files(base_dir, 
                    pattern = paste0("(-|_)", pattern), 
                    ignore.case = T, 
                    full.names = T,
                    recursive = T)
  lapply(x, reader, ...) %>% setNames(x)
}

# BEELINE metrics
metric = "aupr"
aupr = grabResults(metric)
plot_data = list()
for(fname in names(aupr)){
  aupr[[fname]] %<>% 
    tidyr::pivot_longer(cols = !X, values_to = "metric") %>%
    tidyr::separate(name, into = c(NA, "network", "cellcount", "replicate")) %>%
    dplyr::rename(method=X) %>%
    dplyr::mutate(cellcount = factor(cellcount, levels = gtools::mixedsort(unique(cellcount))))
}
aupr %<>% data.table::rbindlist()
ggplot(aupr) + 
  geom_violin(aes(x = cellcount, y = metric, colour = method, shape = method)) + 
  geom_point(aes(x = cellcount, y = metric, colour = method, shape = method)) + 
  facet_wrap(~network) + 
  ylab(metric) +
  ggtitle(paste0(metric, " on BEELINE simple simulations"))

# Calibration checks based on BEELINE ground truth
metric = "undirectedFDR"
fdr = grabResults(pattern = metric) 
plot_data = fdr %>% 
  data.table::rbindlist() %>%
  tidyr::pivot_longer(cols = X0:X9, values_to = "empirical_fdr", names_to = "targeted_fdr") %>%
  dplyr::mutate(targeted_fdr = gsub("^X", "", targeted_fdr) %>% as.numeric %>% divide_by(10)) %>% 
  tidyr::separate(X, into = c(NA, "network", "cellcount", "replicate")) 
ggplot(plot_data) + 
  geom_point(aes(x = targeted_fdr, y = empirical_fdr, colour = cellcount, shape = cellcount)) + 
  geom_smooth(aes(x = targeted_fdr, y = empirical_fdr, colour = cellcount, group = cellcount), se = F) + 
  facet_wrap( ~ network) + 
  ylab(metric) +
  ggtitle("Calibration on BEELINE simple network simulations") + 
  geom_abline(aes(slope = 1, intercept = 0))

# Calibration checks based on simulated Y
calibration_checks = grabResults(pattern = "calibration.Rda", 
                                 reader = readRDS) 
plot_data = list()
for(fname in names(calibration_checks)){
  plot_data[[fname]] = data.frame(
    empirical_fdr = calibration_checks[[fname]]$calibration$fdr %>% colMeans, 
    targeted_fdr  = calibration_checks[[fname]]$calibration$targeted_fdrs, 
    network = basename(dirname(dirname(dirname(fname)))),
    replicate = basename(dirname(dirname(fname))) %>% strsplit("-") %>% extract2(1) %>% extract2(4),
    cellcount = basename(dirname(dirname(fname))) %>% strsplit("-") %>% extract2(1) %>% extract2(3)
  )
}
plot_data %<>% data.table::rbindlist()
ggplot(plot_data) + 
  geom_point(aes(x = targeted_fdr, y = empirical_fdr, colour = cellcount, shape = cellcount)) + 
  facet_wrap(~network) + 
  ggtitle("Calibration on BEELINE simple network simulations") + 
  geom_abline(slope=1, intercept = 0)
  