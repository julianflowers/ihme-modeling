
dir <- getwd()
source("anclik/anclik.R")
setwd(dir)
rm(dir)

source("R/epp.R")
source("R/generics.R")

source("R/IMIS.R")

library(parallel)

#################
####  Prior  ####
#################

ldinvgamma <- function(x, alpha, beta){
  log.density <- alpha * log(beta) - lgamma(alpha) - (alpha + 1) * log(x) - (beta/x)
  return(log.density)
}

## r-spline prior parameters
logiota.unif.prior <- c(log(1e-14), log(0.000025))
tau2.prior.rate <- 0.5

invGammaParameter <- 0.001   #Inverse gamma parameter for tau^2 prior for spline
muSS <- 1/11.5               #1/duration for r steady state prior

ancbias.pr.mean <- 0.15
# ancbias.pr.sd <- 1
ancbias.pr.sd <- 0.04
if (grepl('USA', iso3)) {
  ancbias.pr.sd <- 0.004
  ancbias.pr.mean <- 0
}

## r-trend prior parameters
t0.unif.prior <- c(1970, 1990)
t1.unif.prior <- c(10, 30)
logr0.unif.prior <- c(1/11.5, 10)
rtrend.beta.pr.sd <- 0.2
  

lprior <- function(theta, fp){

  if(!exists("eppmod", where = fp))  # backward compatibility
    fp$eppmod <- "rspline"

  if(fp$eppmod == "rspline"){
    nk <- fp$numKnots
    tau2 <- exp(theta[nk+3])
    
    return(sum(dnorm(theta[3:nk], 0, sqrt(tau2), log=TRUE)) +
           dunif(theta[nk+1], logiota.unif.prior[1], logiota.unif.prior[2], log=TRUE) + 
           dnorm(theta[nk+2], ancbias.pr.mean, ancbias.pr.sd, log=TRUE) +
           ldinvgamma(tau2, invGammaParameter, invGammaParameter))
  } else { # rtrend

    return(dunif(theta[1], t0.unif.prior[1], t0.unif.prior[2], log=TRUE) +
           dunif(theta[2], t1.unif.prior[1], t1.unif.prior[2], log=TRUE) +
           dunif(theta[3], logr0.unif.prior[1], logr0.unif.prior[2], log=TRUE) +
           sum(dnorm(theta[4:7], 0, rtrend.beta.pr.sd, log=TRUE)) +
           dnorm(theta[8], ancbias.pr.mean, ancbias.pr.sd, log=TRUE))
  }
}

################################
####                        ####
####  HH survey likelihood  ####
####                        ####
################################

fnPrepareHHSLikData <- function(hhs, anchor.year = 1970L){
  hhs$W.hhs <- qnorm(hhs$prev)
  hhs$v.hhs <- 2*pi*exp(hhs$W.hhs^2)*hhs$se^2
  hhs$sd.W.hhs <- sqrt(hhs$v.hhs)
  hhs$idx <- hhs$year - (anchor.year - 1)

  hhslik.dat <- subset(hhs, used)
  return(hhslik.dat)
}

fnHHSll <- function(qM, hhslik.dat){
  return(sum(dnorm(hhslik.dat$W.hhs, qM[hhslik.dat$idx], hhslik.dat$sd.W.hhs, log=TRUE)))
}


###########################
####                   ####
####  Full likelihood  ####
####                   ####
###########################

fnCreateLikDat <- function(epp.data, anchor.year=1970L){

  likdat <- list(anclik.dat = fnPrepareANCLikelihoodData(epp.data$anc.prev, epp.data$anc.n, , anchor.year=anchor.year),
                 hhslik.dat = fnPrepareHHSLikData(epp.data$hhs, anchor.year=anchor.year))
  likdat$lastdata.idx <- max(unlist(likdat$anclik.dat$anc.idx.lst), likdat$hhslik.dat$idx)
  likdat$firstdata.idx <- min(unlist(likdat$anclik.dat$anc.idx.lst), likdat$hhslik.dat$idx)
  return(likdat)
}

fnCreateParam <- function(theta, fp){

  if(!exists("eppmod", where = fp))  # backward compatibility
    fp$eppmod <- "rspline"

  if(fp$eppmod == "rspline"){
    u <- theta[1:fp$numKnots]
    beta <- numeric(fp$numKnots)
    beta[1] <- u[1]
    beta[2] <- u[1]+u[2]
    for(i in 3:fp$numKnots)
      beta[i] <- -beta[i-2] + 2*beta[i-1] + u[i]
    
    return(list(rvec = as.vector(fp$rvec.spldes %*% beta),
                iota = exp(theta[fp$numKnots+1]),
                ancbias = theta[fp$numKnots+2]))
  } else { # rtrend
    return(list(tsEpidemicStart = fp$proj.steps[which.min(abs(fp$proj.steps - theta[1]))], # t0
                rtrend = list(tStabilize = theta[1]+theta[2],  # t0 + t1
                              r0 = exp(theta[3]),              # r0
                              beta = theta[4:7]),
                ancbias = theta[8]))
  }
}

ll <- function(theta, fp, likdat){

  param <- fnCreateParam(theta, fp)
  fp <- update(fp, list=param)

  if(!exists("eppmod", where=fp) || fp$eppmod == "rspline")
    if(min(fp$rvec)<0 || max(fp$rvec)>20) # Test positivity of rvec
      return(-Inf)
  
  mod <- fnEPP(fp)

  qM.all <- qnorm(prev(mod))
  qM.preg <- if(exists("pregprev", where=fp) && fp$pregprev) qnorm(fnPregPrev(mod, fp)) else qM.all

  if(any(is.na(qM.all)) || any(qM.all[likdat$firstdata.idx:likdat$lastdata.idx] == -Inf))
    return(-Inf)

  ll.anc <- log(fnANClik(qM.preg+fp$ancbias, likdat$anclik.dat))
  ll.hhs <- fnHHSll(qM.all, likdat$hhslik.dat)

  if(exists("equil.rprior", where=fp) && fp$equil.rprior){
    rvec.ann <- fp$rvec[fp$proj.steps %% 1 == 0.5]
    equil.rprior.mean <- muSS/(1-pnorm(qM.all[likdat$lastdata.idx]))
    equil.rprior.sd <- sqrt(mean((muSS/(1-pnorm(qM.all[likdat$lastdata.idx - 10:1])) - rvec.ann[likdat$lastdata.idx - 10:1])^2))  # empirical sd based on 10 previous years
    ll.rprior <- sum(dnorm(rvec.ann[(likdat$lastdata.idx+1L):length(qM.all)], equil.rprior.mean, equil.rprior.sd, log=TRUE))  # prior starts year after last data
  } else
    ll.rprior <- 0
  
  return(ll.anc+ll.hhs+ll.rprior)
}


##########################
####  IMIS functions  ####
##########################

## Note: requires fp and likdat to be in global environment

sample.prior <- function(n){

  if(!exists("eppmod", where = fp))  # backward compatibility
    fp$eppmod <- "rspline"

  if(fp$eppmod == "rspline"){
       
    mat <- matrix(NA, n, fp$numKnots+3)

    ## sample penalty variance
    tau2 <- rexp(n, tau2.prior.rate)                  # variance of second-order spline differences
    
    mat[,1] <- rnorm(n, 1.5, 1)                                                     # u[1]
    mat[,2:fp$numKnots] <- rnorm(n*(fp$numKnots-1), 0, sqrt(tau2))                  # u[2:numKnots]
    mat[,fp$numKnots+1] <-  runif(n, logiota.unif.prior[1], logiota.unif.prior[2])  # iota
    mat[,fp$numKnots+2] <-  rnorm(n, ancbias.pr.mean, ancbias.pr.sd)                # ancbias parameter
    mat[,fp$numKnots+3] <- log(tau2)                                                # tau2

  } else { # r-trend

    mat <- matrix(NA, n, 8)

    mat[,1] <- runif(n, t0.unif.prior[1], t0.unif.prior[2])        # t0
    mat[,2] <- runif(n, t1.unif.prior[1], t1.unif.prior[2])        # t1
    mat[,3] <- runif(n, logr0.unif.prior[1], logr0.unif.prior[2])  # r0
    mat[,4:7] <- rnorm(4*n, 0, rtrend.beta.pr.sd)                  # beta
    mat[,8] <- rnorm(n, ancbias.pr.mean, ancbias.pr.sd)            # ancbias parameter
  }
  
  return(mat)
}

prior <- function(theta){
  return(unlist(mclapply(seq_len(nrow(theta)), function(i) return(exp(lprior(theta[i,], fp))), mc.cores=3)))
}

likelihood <- function(theta){
  return(unlist(mclapply(seq_len(nrow(theta)), function(i) return(exp(ll(theta[i,], fp, likdat))), mc.cores=3)))
}
