#' @title contributions_model
#' @description mlr3 model for predicting a customer's first contribution
#' @export
#' @name contributions_model
contributions_model <- report(class=c("contributions_model","mlr_report"))

#' @describeIn contributions_model Build the contributions dataset from the overall stream.
#' * events are the first contribution per household > $50
#' * data after an event are censored
#' * contribution indicators are rolled back and timestamps are normalized to the start of customer activity
#' * only data since `since` are loaded
#' Data is written to the primary cache partitioned by year and then synced across storages
#' @param since Date/POSIXct data on or after this date will be loaded and possibly used for training
#' @param ... not used
#' @importFrom ff delete
contributions_dataset <- function(since = Sys.Date()-365*5, until = Sys.Date(),
                                  rebuild_dataset = NULL, ...) {


  . <- stream <- group_customer_no <- timestamp <- event_type <- event <- contribution_amt <- n_event <-
    N <- partition <- NULL

  dataset_max_date <- NULL
  if (is.null(rebuild_dataset) && cache_exists_any("dataset","contributions_model") || !(rebuild_dataset %||% T)) {
    dataset <- read_cache("dataset","contributions_model")
    dataset_max_date <- summarise(dataset,max(date,na.rm = T)) %>% collect %>% .[[1]]

    if(dataset_max_date >= until || !(rebuild_dataset %||% T))
      return(dataset %>% filter(date >= since & date < until))
  }

  stream <- read_cache("stream", "stream", include_partition = TRUE)
  stream_key <- stream %>%
    select(all_of(c("group_customer_no","timestamp","event_type","contribution_amt"))) %>%
    collect %>% setDT

  stream_key[,I:=.I]
  setkey(stream_key,group_customer_no,timestamp)

  # add event
  stream_key[,event := event_type == "Contribution" & contribution_amt>=50]
  stream_key[,`:=`(n_event = cumsum(event),
                   N = .N), by="group_customer_no"]
  # censor
  stream_key <- stream_key[n_event == 0 | event & n_event==1 & N>1]
  stream_key[,`:=`(n_event = NULL, N = NULL)]

  # filter dates
  stream_key <- stream_key[timestamp >= dataset_max_date %||% since & timestamp < until]

  # subsample
  stream_key[, date := as.Date(timestamp)]
  setorder(stream_key, group_customer_no, date, -event)
  stream_key <- stream_key[, first(.SD), by = c("group_customer_no", "date")]

  # partition by year
  stream_key[,partition := year(timestamp)]

  if(nrow(stream_key) > 0) {
    stream_key[,dataset_chunk_write(dataset = stream, partition = partition,
                                    dataset_name = "contributions_model",
                                    rows = .SD,
                                    cols = grep("Adj",colnames(stream),value=T,invert = T),
                                    rollback_cols = grep("^(contribution|ticket)",colnames(stream),value = T) %>%
                                      grep(pattern = "Adj",value=T,invert = T)),
               by = "partition"]
    tessilake::sync_cache("dataset", "contributions_model", overwrite = TRUE)
  }


  return(read_cache("dataset","contributions_model") %>%
           filter(date >= since & date < until))

}

#' @export
#' @importFrom tessilake read_cache cache_exists_any
#' @importFrom dplyr filter select collect mutate summarise
#' @importFrom mlr3 TaskClassif
#' @describeIn contributions_model Read in contribution data and prepare a mlr3 training task and a prediction/validation task
#'
#' @param model `contributions_model` object
#' @param predict_since Date/POSIXct data on/after this date will be used to make predictions and not for training
#' @param predict Not used, just here to prevent partial argument matching
#' @param until Date/POSIXct data after this date will not be used for training or predictions, defaults to the beginning of today
#' @param rebuild_dataset boolean rebuild the dataset by calling `contributions_dataset(since=since,until=until)` (TRUE), just read the existing one (FALSE),
#' or append new rows by calling `contributions_dataset(since=max_existing_date,until=until)` (NULL, default)
#' @param downsample_read `numeric(1)` the amount to downsample the dataset on read
#' @note Data will be loaded in-memory, because *\[inaudible\]* mlr3 doesn't work well with factors encoded as dictionaries in arrow tables.
read.contributions_model <- function(model,
                                     since = Sys.Date()-365*5,
                                     until = Sys.Date(),
                                     predict_since = Sys.Date() - 30,
                                     rebuild_dataset = NULL,
                                     downsample_read = .1,
                                     predict = NULL, ...) {

  . <- event <- date <- TRUE

  dataset <- contributions_dataset(since = since, until = until,
                                   rebuild_dataset = rebuild_dataset)

  dataset <- rbind(filter(dataset, date >= predict_since | event == "TRUE") %>%
                     collect %>% setDT,
                   filter(dataset, date < predict_since & event == "FALSE") %>%
                     dplyr::slice_sample(prop = downsample_read) %>%
                     collect %>% setDT) %>%
    .[,`:=`(event = as.factor(event),
            date = as.POSIXct(date))]


  numeric_cols <- names(sapply(dataset, is.numeric)) %>% setdiff(c("event","date"))
  dataset[,(numeric_cols) := lapply(.SD,as.numeric), .SDcols = numeric_cols]

  model$task <- TaskClassif$new(id = "contributions",
                                target = "event",
                                backend = dataset)

  # label columns + rows
  model$task$col_roles$feature <- grep("^(email|contribution|address|ticket).+(amt|count|level|max|min)|timestamp",
                                       names(dataset),value=T,ignore.case=T,perl=T)

  model$task$col_roles$order <- "timestamp"
  model$task$col_roles$group <- "group_customer_no"
  model$task$positive <- "TRUE"

  model$task$internal_valid_task <- dataset[date >= predict_since,which=T]

  NextMethod()
}

#' @export
#' @importFrom tessilake cache_primary_path
#' @importFrom mlr3verse po to_tune flt lts ppl tune `%>>%` p_int tnr selector_invert selector_grep
#' @importFrom mlr3 msr rsmp as_learner lrn
#' @importFrom bbotk mlr_optimizers
#' @importFrom bestNormalize yeojohnson
#' @importFrom ranger ranger
#' @describeIn contributions_model Tune and train a stacked log-reg/ranger model on the data
#' @details
#' # Preprocessing:
#' * ignore 1-day and email "send" features because they leak data
#' * remove constant features
#' * balance classes to a ratio of 1:10 T:F
#' * Yeo-Johnson with tuned boundaries
#' * impute missing values out-of-range and add missing data indicator features
#' * feature importance filter (for log-reg submodel only)
#' # Model:
#' * stacked log-reg + ranger > log-reg model
#' * tuned using a hyperband method on the AUC (sensitivity/specificity)
#' @param num_trees `integer(1)` maximum number of trees to use for ranger model
train.contributions_model <- function(model, num_trees = 512, ...) {
  subsample <- po("subsample", frac = .1)

  preprocess <- po("select",selector = selector_invert(selector_grep("__1|Send", perl = T))) %>>%
                po("classbalancing", reference = "minor",ratio = 10,adjust="downsample") %>>%
                ppl("robustify") %>>%
                po("filter", filter = flt("find_correlation"), filter.cutoff = .5) %>>%
                po("yeojohnson", lower = to_tune(-2,0), upper = to_tune(0,2), eps = .1)

  importance_filter <- po("filter",
                   filter = flt("importance"),
                   filter.frac = to_tune(.1,.67))

  logreg <- as_learner(importance_filter %>>% lrn("classif.log_reg", predict_type = "prob"), id = "logreg")
  ranger <- as_learner(lrn("classif.ranger", predict_type = "prob",
                           mtry.ratio = to_tune(.1,1),
                           sample.fraction = to_tune(.1,1),
                           num.trees = to_tune(p_int(num_trees/8,num_trees,tags="budget"))), id = "ranger")

  stacked <- as_learner(preprocess %>>% ppl("stacking", c(logreg,ranger),
                                                           lrn("classif.log_reg", predict_type = "prob"),
                                                           use_features = FALSE), id = "stacked")
  stacked_tuned <- tune(
      tuner = tnr("hyperband",eta=2),
      task = model$task,
      learner = stacked,
      resampling = rsmp("holdout"),
      measures = msr("classif.auc"))

  stacked$param_set$values <- stacked_tuned$result_learner_param_vals

  model$model <- stacked$train(model$task)

  NextMethod()
}

#' @export
#' @importFrom tessilake cache_primary_path read_cache
#' @importFrom dplyr filter
#' @describeIn contributions_model Predict using the trained model
predict.contributions_model <- function(model, ...) {
  if(is.null(model$model))
    model$model <- load_model("contributions_model")

  model$predictions <-
    cbind(as.data.table(model$model$predict(model$task$internal_valid_task)),
          model$task$internal_valid_task$data(cols = c("I","group_customer_no","date")))

  NextMethod()
}

#' @describeIn contributions_model create IML reports for contributions_model
#' @importFrom dplyr inner_join
#' @importFrom ggplot2 coord_flip theme_minimal theme scale_y_discrete element_text element_blank
#' @importFrom purrr walk
#' @importFrom tessilake cache_primary_path
#' @importFrom stats runif
#' @param downsample_output `numeric(1)` the amount to downsample the test set by for feature importance and
#' Shapley explanations
#' @export
output.contributions_model <- function(model, downsample_output = .01, ...) {
  prob.TRUE <- explanation <- NULL

  model <- NextMethod()

  model$dataset <- mutate(model$dataset, date = as.Date(date))
  model$predictions <- mutate(model$predictions, date = as.Date(date))

  dataset_predictions <- inner_join(model$dataset,model$predictions,
                                    by = c("group_customer_no","date","I")) %>% collect %>% setDT

  # Feature importance
  fi <- iml_featureimp(model$model, dataset_predictions[runif(.N)<downsample_output])
  top_features <- fi$results[1:25,"feature"]

  pfi <- plot(fi) + coord_flip() +
    theme_minimal(base_size = 8) +
    theme(axis.text.x = element_text(angle = 90, hjust = 1)) +
    scale_y_discrete(limits=rev)
  # remove styling of points
  walk(pfi$layers, \(.) .$aes_params <- list())

  # Feature effects across whole population
  fe1 <- iml_featureeffects(model$model, dataset_predictions[runif(.N)<downsample_output], top_features)
  pfe1 <- plot(fe1, fixed_y = F) &
    theme_minimal(base_size = 8) + theme(axis.title.y = element_blank())

  # Feature effects for top picks
  fe2 <- iml_featureeffects(model$model, dataset_predictions[prob.TRUE > .75], top_features)
  pfe2 <- plot(fe2, fixed_y = F) &
    theme_minimal(base_size = 8) + theme(axis.title.y = element_blank())

  pdf_filename <- cache_primary_path("contributions_model.pdf","contributions_model")
  write_pdf({
    pdf_plot(pfi, "Global feature importance","First contributions model")
    pdf_plot(pfe1, "Local feature effects","First contributions model, full dataset")
    pdf_plot(pfe2, "Local feature effects","First contributions model, likelihood > .75")
  }, .title = "Contributions model", output_file = pdf_filename)

  # Shapley explanations
  to_explain <- dataset_predictions[prob.TRUE>.75]
  ex <- iml_shapley(model$model, dataset_predictions[runif(.N)<downsample_output],
                    x.interest = to_explain, sample.size = 10)

  to_explain[,explanation := map(ex,"results")]
  saveRDS(to_explain, cache_primary_path("shapley.Rds", "contributions_model"))

}

