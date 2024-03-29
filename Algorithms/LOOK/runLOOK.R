suppressPackageStartupMessages({
  library(ggplot2)
  library(magrittr)
  library(optparse)
  library(mclust)
})
option_list <- list (
  make_option(c("-e","--expressionFile"), type = 'character',
              help= "Path to comma separated file containing gene-by-cell matrix with
              cell names as the first row and gene names as
              the first column. Required."),
  make_option(c("-o","--outFile"), type = 'character',
              help= "outFile name to write the output ranked edges. Required."),
  make_option(c("-c","--calibrate"), action = 'store', default = FALSE,
              type = 'logical',
              help= "Run a simple check with additional simulated target genes?"),
  make_option(c("-k","--knockoff_type"),
              type = 'character',
              help= "Knockoff generation method. Options are 'naive', 'gaussian', or 'mixture'."),
  make_option(c("-d","--data_mode"),
              type = 'character',
              help= "Data to make available. Options are 'easy' (protein concentration and RNA production revealed) and  'rna_only'.")

  )
parser <- OptionParser(option_list = option_list)
arguments <- parse_args(parser, positional_arguments = FALSE)

nonparametricMarginalScreen = function(X, knockoffs, y){
  sapply(1:ncol(X), function(k) loess(y ~ knockoffs[,k])$s - loess(y ~ X[,k])$s )
}

# For manual testing of the script
# arguments = list(
#   expressionFile = "~/Desktop/jhu/research/projects/Beeline/inputs/Synthetic_with_protein_and_velocity/dyn-LL/dyn-LL-500-1/LOOK/ExpressionData.csv",
#   outFile = "~/Desktop/jhu/research/projects/Beeline/temp/outputs.txt",
#   calibrate = T,
#   data_mode = "rna_only",
#   knockoff_type = "naive"
# )

standardize = function(inputExpr){
  for(i in seq(nrow(inputExpr))){
    inputExpr[i,] = inputExpr[i,] - mean(inputExpr[i,])
    inputExpr[i,] = inputExpr[i,] / (1e-8 + sd(inputExpr[i,]))
  }
  inputExpr
}
# Input expression data
inputPT =
  arguments$expressionFile %>%
  dirname %>%
  dirname %>%
  file.path("PseudoTime.csv") %>%
  read.table(sep = ",", header = 1, row.names = 1)
inputExpr <- read.table(arguments$expressionFile, sep=",", header = 1, row.names = 1)
inputExpr = inputExpr[,order(inputPT[[1]])]
inputPT   = inputPT[order(inputPT[[1]]),1]
stopifnot("Pseudotime and expression don't have the same number of cells.\n"=
            nrow(inputPT)==ncol(inputExpr))
# Separate different types of measurements
inputProtein     = inputExpr[grepl("^p_", rownames(inputExpr)),]
inputRNA         = inputExpr[grepl("^x_|^g", rownames(inputExpr)),]
inputRNAvelocity = inputExpr[grepl("^velocity_x_", rownames(inputExpr)),]
inputRNA = as.matrix(inputRNA) %>% standardize
# Gene name handling:
# Clean
geneNames_more_like_cleanNames = function(x){
  x %>% gsub("^velocity_", "", .) %>% gsub("^(p|x)_", "", .)
}
geneNames <- rownames(inputRNA) %>% geneNames_more_like_cleanNames
rownames(inputRNA) <- geneNames
# Sort
geneNames %<>% gtools::mixedsort()
inputRNA = inputRNA[geneNames, ]
# Clean and sort other types of measurements
if(nrow(inputProtein)>0){
  inputProtein = as.matrix(inputProtein) %>% sqrt %>% standardize
  rownames(inputProtein) %<>% geneNames_more_like_cleanNames
  inputProtein = inputProtein[geneNames, ]
}
if(nrow(inputRNAvelocity)>0){
  inputRNAvelocity = as.matrix(inputRNAvelocity) %>% standardize
  rownames(inputRNAvelocity) %<>% geneNames_more_like_cleanNames
  inputRNAvelocity = inputRNAvelocity[geneNames, ]
}
rm(inputExpr)

# Robust heuristic to separate velocity into decay + production; based on
# piecewise quantile regression of RNA velocity against RNA concentration.
getProductionRate = function(inputRNAvelocity, inputRNA){
  production = inputRNAvelocity * 0
  for(k in seq_along(geneNames)){
    y = t(inputRNAvelocity)[,k]
    # Diagnostic plots will be saved; we add each quant reg separately so the pdf stays open. Ugly; sorry.
    dir.create(file.path(dirname(arguments$outFile), "decay_estimation"), recursive = T, showWarnings = F)
    pdf(       file.path(dirname(arguments$outFile), "decay_estimation", paste0("g", k, ".pdf")))
    {
      concentration = inputRNA[k,]
      plot(concentration, y, pch = ".")
      concentration_bins = cut(concentration, breaks = 10)
      decay_rate_constant = list()
      for(bin in levels(concentration_bins)){
        idx = concentration_bins==bin
        if(sum(idx)<10){next}
        decay_rate_constant[[bin]] = coef( quantreg::rq(y[idx] ~ concentration[idx] ) )
        clip(min(concentration[idx]), max(concentration[idx]), y1 = -100, y2 = 100)
        abline(decay_rate_constant[[bin]][[1]], decay_rate_constant[[bin]][[2]])
      }
      nona = function(x) x[!is.na(x)]
      negative_only = function(x) x[x<0]
      decay_rate_constant %<>% sapply(extract2, "concentration[idx]") %>% nona %>% negative_only %>% median
      clip(min(concentration), max(concentration[idx]), y1 = -100, y2 = 100)
      abline(a = 0, b = decay_rate_constant, col = "red")
    }
    dev.off()
    production[k, ] = y - concentration*decay_rate_constant
  }
  return(production)
}

# Simulate additional target genes with simple dependence on X to check subset selection fdr control
runCalibrationCheck = function(X, X_k, noiselevel = 1){
  if(arguments$calibrate){
    diverse_y = rlookc::chooseDiverseY(X, n_quantiles = 20)
    calibration_results = rlookc::findWorstY(
      X,
      X_k,
      y = diverse_y$y,
      ground_truth = diverse_y$ground_truth
    )
    saveRDS(calibration_results, file.path(dirname(arguments$outFile), "calibration.Rda"))
    return(invisible(calibration_results))
  }
}

# Functions for modeling covariates and knockoff construction
fitMixtureModel = function(X){
  mixtureModel = mclust::Mclust(X, G = 100, modelNames = "EII")
  # Assess mixture model fit
  try(silent = T, {
    exprByCluster =
      X %>%
      t %>%
      as.data.frame() %>%
      cbind( cluster = apply( mixtureModel$z, 1, which.max ) ) %>%
      cbind( time = inputPT ) %>%
      tidyr::pivot_longer(seq(ncol(X)), names_to = "gene", values_to = "expression")
    ggplot(exprByCluster) +
      geom_point(aes(x = time, y = expression, color = cluster)) +
      facet_wrap(~gene) +
      ggtitle("Gaussian mixture model fit")
    ggsave(file.path(dirname(arguments$outFile), "mixture_model_fit.pdf"), width = 8, height = 8)

    g1 = inputProtein %>% rownames         %>% extract2(1)
    other_genes =  inputProtein %>% rownames %>% extract(c(2, floor( nrow(inputProtein)/2 ), nrow(inputProtein)))
    for( g2 in other_genes){
      title = paste("Genes", g1, "and", g2)
      inputProtein %>%
        t %>%
        as.data.frame() %>%
        cbind( cluster = apply( mixtureModel$z, 1, which.max ) %>% paste0("cluster", .) ) %>%
        cbind( time = inputPT ) %>%
        ggplot() +
        geom_point(aes_string(x = g1, y = g2, color = "time")) +
        facet_wrap(~cluster) +
        ggtitle(title)
      ggsave(file.path(dirname(arguments$outFile), paste0("mixture_model_fit_", title, ".pdf")),
             width = 8, height = 8)
    }
  })
  mixtureModel
}
generateKnockoffs = function(X, knockoff_type = arguments$knockoff_type){
  if(knockoff_type == "identical"){
    knockoffs = X
  } else if(knockoff_type == "naive"){
    r = rownames(X)
    knockoffs = X %>% apply(2, sample) %>% set_rownames(r)
  } else if(knockoff_type == "gaussian"){
    knockoffs = X %>% knockoff::create.second_order()
  } else if(knockoff_type == "mixture"){
    mixtureModel = fitMixtureModel(X)
    mus    = lapply( 1:mixtureModel$G, function(g) mixtureModel$parameters[["mean"    ]]           [,g] )
    sigmas = lapply( 1:mixtureModel$G, function(g) mixtureModel$parameters[["variance"]][["sigma"]][,,g] )
    knockoffs = rlookc::computeGaussianMixtureKnockoffs( X,
                                                         mus,
                                                         sigmas,
                                                         do_high_dimensional = F,
                                                         posterior_probs = mixtureModel$z,
                                                         output_type = "knockoffs")
  } else {
    stop("knockoff_type not recognized")
  }
  return(knockoffs)
}

# Core functionality: GRN inference via knockoff-based tests
# of conditional independence
applyKnockoffFilter = function(data_mode = arguments$data_mode){
  if( data_mode == "easy" ){
    stopifnot("Protein levels must be provided with prefix 'p_'.          \n"=nrow(inputProtein)>0)
    stopifnot("Velocity levels must be provided with prefix 'velocity_x_'.\n"=nrow(inputRNAvelocity)>0)
    knockoffs = generateKnockoffs(t(inputProtein))
    write.csv(knockoffs,       paste0(dirname(arguments$outFile), "/knockoffs.csv"))
    write.csv(t(inputProtein), paste0(dirname(arguments$outFile), "/data.csv"))
    runCalibrationCheck(X = t(inputProtein), X_k = knockoffs)
    inputRNAproduction = getProductionRate(inputRNAvelocity = inputRNAvelocity, inputRNA = inputRNA)
    knockoffResults = lapply(
      seq(nrow(inputRNAproduction)),
      function(i) knockoff::stat.glmnet_lambdasmax( t(inputProtein), knockoffs, y = inputRNAproduction[i,] )[-i]
    )
  } else if (data_mode == "rna_only") {
    # Save regular knockoffs for later visualization 
    write.csv(generateKnockoffs(t(inputRNA)), paste0(dirname(arguments$outFile), "/knockoffs.csv"))
    write.csv(t(inputRNA),                    paste0(dirname(arguments$outFile), "/data.csv"))
    # Need leave-one-out knockoffs for actual network inference
    knockoffs = lapply(1:ncol(t(inputRNA)), function(i) generateKnockoffs(t(inputRNA[-i,])))
    runCalibrationCheck(X = t(inputRNA), X_k = generateKnockoffs(t(inputRNA)))
    knockoffResults = lapply(
      seq(nrow(inputRNA)),
      function(i) knockoff::stat.glmnet_lambdasmax( t(inputRNA[-i,]), knockoffs[[i]], y = inputRNA[i,] )
    )
  } else {
    stop("data_mode not recognized")
  }
  # Cleanup yields a tidy dataframe
  DF = list()
  for(i in seq(nrow(inputRNA))){
    DF[[i]] = data.frame(
      Gene1 = geneNames[-i],
      Gene2 = geneNames[ i],
      knockoff_stat = knockoffResults[[i]]
    )
  }
  DF = data.table::rbindlist(DF)
  DF[["q_value"]] = rlookc::knockoffQvals(DF[["knockoff_stat"]], offset = 0)
  DF
}

# Are different types of knockoffs visibly different w.r.t. real X, real Y, or time?
if(arguments$knockoff_type=="mixture" & arguments$data_mode=="easy"){
  inputRNAproduction = getProductionRate(inputRNAvelocity, inputRNA)
  knockoffs = list()
  for(kt in c("mixture", "gaussian", "naive", "identical")){
    knockoffs[[kt]] = generateKnockoffs(t(inputProtein), knockoff_type = kt) %>% as.data.frame()
    knockoffs[[kt]][["knockoff_type"]] = kt
    knockoffs[[kt]][["production_gene2"]] = inputRNAproduction[2,]
    knockoffs[[kt]][["production_gene3"]] = inputRNAproduction[3,]
    knockoffs[[kt]][["time"]] = inputPT
  }
  plot_data = data.table::rbindlist(knockoffs)
  knockoff_type_color_mapping =
    scale_color_manual(values = c("identical" ="black",
                                  "naive" = "blue",
                                  "gaussian" ="red",
                                  "mixture" = "orange"))
  goodness_of_fit_plots = file.path(dirname(arguments$outFile), "knockoff_goodness_of_fit_plots")
  dir.create(goodness_of_fit_plots, recursive = T, showWarnings = F)
  try(silent = T, {
    # A true regulator vs Y. In all toy networks, g1 regulates g2 directly.
    ggplot(plot_data) +
      geom_point(aes(x = g1, y = production_gene2, colour = knockoff_type, shape = knockoff_type)) +
      ggtitle(paste0("A candidate and its knockoffs vs a gene that is directly affected")) +
      knockoff_type_color_mapping
    ggsave(goodness_of_fit_plots %>% file.path(paste0("true_association.pdf")), width = 6, height = 4)
    # A null variable vs Y. In all toy networks, g1 does not regulate g3 directly.
    ggplot(plot_data) +
      geom_point(aes(x = g1, y = production_gene3, colour = knockoff_type, shape = knockoff_type)) +
      ggtitle(paste0("A candidate and its knockoffs vs a gene not directly affected")) +
      knockoff_type_color_mapping
    ggsave(goodness_of_fit_plots %>% file.path(paste0("no_association.pdf")), width = 6, height = 4)
    # A gene over time
    ggplot(plot_data) +
      geom_point(aes(x = time, y = g1, colour = knockoff_type, shape = knockoff_type)) +
      geom_smooth(aes(x = time, y = g1, colour = knockoff_type), method = "loess", formula = y ~ x, se = F) +
      ggtitle(paste0("Protein expression and knockoffs over time")) +
      knockoff_type_color_mapping
    ggsave(goodness_of_fit_plots %>% file.path(paste0("timeseries.pdf")),
           width = 6, height = 4)
  } )
}

# DO IT
DF = applyKnockoffFilter()

# What's the pattern of discoveries?
try({
  p = ggplot(DF) +
    geom_tile(
      aes(
        x = Gene1 %>% gsub("^g", "", .) %>% as.numeric,
        y = Gene2 %>% gsub("^g", "", .) %>% as.numeric,
        fill = knockoff_stat
      )
    ) +
    geom_point(
      aes(
        x = Gene1 %>% gsub("^g", "", .) %>% as.numeric,
        y = Gene2 %>% gsub("^g", "", .) %>% as.numeric,
        alpha = q_value < 0.25
      ),
      colour = "red"
    ) +
    xlab("Target") + ylab("TF") +
    ggtitle("Pattern of discoveries")
  print(p)
  ggsave(paste0(dirname(arguments$outFile), "/discoveries.pdf"), p, width = 6, height = 6)
})

# Write output to a file
outDF <- DF[order(DF$q_value, decreasing=FALSE), ]
write.table(outDF, arguments$outFile, sep = "\t", quote = FALSE, row.names = FALSE)
warnings()
