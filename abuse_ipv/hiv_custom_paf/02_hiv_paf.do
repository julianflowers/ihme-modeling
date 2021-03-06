// Set preferences for STATA
	// Clear memory and set memory and variable limits
		clear all
		set mem 12g
		set maxvar 32000
	// Set to run all selected code without pausing
		set more off
	// Define J drive (data) for cluster (UNIX) and Windows (Windows)
		if c(os) == "Unix" {
			global prefix "/home/j"
			set odbcmgr unixodbc
		}
		else if c(os) == "Windows" {
			global prefix "J:"
		}


// Run central functions 
	run "$prefix/WORK/10_gbd/00_library/functions/get_ids.ado" 
	run "$prefix/WORK/10_gbd/00_library/functions/get_best_model_versions.ado" 
	run "$prefix/WORK/10_gbd/00_library/functions/get_draws.ado" 


// Test arguments
	/*
	local 1 2 
	local 2 9 
	local 3 150
	*/
// Pass in arguments from launch script	
	
	local version `1'
	local draw_num `2'
	local iso3 `3'

// Locals 
	local data_dir "$prefix/WORK/05_risk/risks/abuse_ipv_hiv/data"
	local rr_dir "$prefix/WORK/05_risk/risks/abuse_ipv_hiv/data/rr/prepped"
	local sex_noncsw_paf "$prefix/WORK/05_risk/risks/unsafe_sex/products/pafs/csw_pafs.xlsx"
	local hiv_dir "/share/epi/risk/temp/ipv_hiv_pafs/hiv_inc_draws"
	local out_dir "/share/epi/risk/temp/ipv_hiv_pafs/v`version'"

	local years "1990 1995 2000 2005 2010 2015"

	local sex 2 // only estimate for females 

// Set up log file 
	cap mkdir "/share/epi/risk/temp/ipv_hiv_pafs/logs/`iso3'"
	log using "/share/epi/risk/temp/ipv_hiv_pafs/logs/`iso3'/log_`iso3'_`draw_num'.smcl", replace 
	
// Get ISO3 with subnational location ids
	run "$prefix/WORK/10_gbd/00_library/functions/get_location_metadata.ado" 
	get_location_metadata, location_set_id(9) clear
	keep if is_estimate == 1 & most_detailed == 1 

	keep ihme_loc_id location_id location_ascii_name super_region_name super_region_id region_name region_id 
	
	rename ihme_loc_id iso3 
	tempfile country_codes
	save `country_codes', replace

	qui: levelsof location_id, local(locations)

// The local "draw_num" represents the final draw number, make local for first draw in group of 100 draws
	local draw_start = `draw_num' - 99	
	
// 1.) Compile IPV prevalence model results from DisMod for all countries, GBD years and age groups
	// Append to make master dataset 

		clear
		get_ids, table(modelable_entity) clear 
		keep if modelable_entity_name == "Intimate partner violence"
		local exp_sequela_id = modelable_entity_id

		di `exp_sequela_id'
		
	 // Get model version id
		clear 
		get_best_model_versions, gbd_team(epi) id_list(`exp_sequela_id')
		local exp_model_version_id = model_version_id 
		di `exp_model_version_id'
		
	// Append years to make master dataset for relevant country and sex
		
		// temporarily disable to test code locally and then reinstate 
		//save "$prefix/WORK/05_risk/risks/abuse_ipv_exp/data/exp/ipv_exposure_draws.dta", replace 
		//use "$prefix/WORK/05_risk/risks/abuse_ipv_exp/data/exp/ipv_exposure_draws_150.dta", replace 
		//keep if location_id == `iso3'

		get_draws, gbd_id_field(modelable_entity_id) gbd_id(`exp_sequela_id') location_ids(`iso3') sex_ids(2) status(latest) source(epi) clear

			tempfile ipv_draws 
			save `ipv_draws', replace 

			insheet using "`data_dir'/convert_to_new_age_ids.csv", comma names clear 
			merge 1:m age_group_id using `ipv_draws', keep(3) nogen

			rename age_start age 

			keep if age >= 15 & age <=80
			order draw_*, sequential
			keep location_id age sex_id year_id draw_`draw_start'-draw_`draw_num'
			
			merge m:1 location_id using `country_codes', keep(3) nogen 
			drop location_ascii_name super_region_* region_*

	// Save aggregated IPV exposure
		rename year_id year 
		rename sex_id sex 
		order iso3 year sex age
		sort iso3 year sex age

		drop iso3 
		rename location_id iso3 

		tempfile exposure_allyrs
		save `exposure_allyrs', replace
		
// 2.) Prepare a dataset that includes both the aggregated IPV exposure data and the proportion of HIV incidence that is sexually transmitted and not from commercial sex workers 
	// Bring in proportion of HIV incidence that is sexually transmitted and not from commercial sex workers
		import excel using "`sex_noncsw_paf'", firstrow clear
		
		merge m:1 iso3 using `country_codes', keep(3) nogen 

	// Aggregate subnational up to national since there are no subnational HIV incidence estimates
		//replace iso3 = substr(iso3, 1,3)
		gen attributable_deaths = prop_sexual_non_csw * mean_abs_death
		collapse (sum) attributable_deaths mean_abs_death, by(location_id age sex year) fast
		gen sexnoncsw = attributable_deaths / mean_abs_death
		drop attributable_deaths mean_abs_death
		
	// Make sex variable comparable with other datasets for merge
		tostring sex, replace
		replace sex = "`sex'"
		keep if location_id == `iso3'

		cap rename year_id year 
		destring sex, replace 

		rename location_id iso3 

	// Merge with IPV  exposure data
		merge 1:1 iso3 year age sex using `exposure_allyrs', nogen keep(match)
	
	// Expand to make observations for year = 1980 and year = 1985
		expand 2 if year == 1990, gen(dup1)
		replace year = 1985 if dup1 == 1
		expand 2 if year == 1985, gen(dup2)
		replace year = 1980 if dup2 == 1
		drop dup*
	
	// Expand again to make observations for each year between GBD 5 year intervals
		expand 5, gen(dup)
	
	// Fill in proper years
		bysort iso3 year age dup: gen y = _n
		forvalues x = 1/4 {
			replace year = year - y if y == `x' & dup == 1 & year != 1980
		}
		
		duplicates drop age iso3 year sex, force
		drop dup y
		
	// Save prepped IPV exposure draws with proportion of HIV that is sexually transmitted 
		tempfile exposure
		save `exposure', replace
	
// 3.) Prep HIV incidence data
	// Bring in dataset (only estimate HIV attributable to IPV in ages 15+)
		
		//insheet using "C:/Users/lalexan1/Desktop/`iso3'_hiv_incidence_draws.csv", comma names clear 
		insheet using "`hiv_dir'/`iso3'_hiv_incidence_draws.csv", comma names clear 

		// Missing HIV incidence data for 1980 in India, Mozambique and Moldova and for 1981 as well in Mozambique so I will assume the same incidence as the following year (need to fix this as to not break loop below)	
		// 88, 106, 113 has another issue 

		merge m:1 location_id using `country_codes', keep(3) nogen 

		// Missing HIV incidence data for 1980 in India, Mozambique and Moldova and for 1981 as well in Mozambique so I will assume the same incidence as the following year (need to fix this as to not break loop below)	
		expand 2, gen(dup)
		replace year = 1981 if iso3 == "MOZ" & year == 1982 & dup == 1
		recode dup (1=0) if iso3 == "MOZ" & year == 1981
		drop if dup == 1
		
		expand 2, gen(dup2)
		replace year = 1980 if regexm(iso3, "IND|MOZ|MDA") & year == 1981 & dup2 == 1
		recode dup2 (1=0) if regexm(iso3, "IND|MOZ|MDA") & year == 1980
		drop if dup2 == 1
		drop dup*

		// Also HIV incidence data for South African provinces doesn't start until 1985, so need to assume the same incidence as the following year 
		expand 2, gen(dup)
		replace year = 1984 if regexm(iso3, "ZAF") & year == 1985 & dup == 1 
		recode dup (1=0) if regexm(iso3, "ZAF") & year == 1984
		drop if dup == 1 
		drop dup 

		expand 2, gen(dup)
		replace year = 1983 if regexm(iso3, "ZAF") & year == 1984 & dup == 1 
		recode dup (1=0) if regexm(iso3, "ZAF") & year == 1983
		drop if dup == 1 
		drop dup 

		expand 2, gen(dup)
		replace year = 1982 if regexm(iso3, "ZAF") & year == 1983 & dup == 1 
		recode dup (1=0) if regexm(iso3, "ZAF") & year == 1982
		drop if dup == 1 
		drop dup 

		expand 2, gen(dup)
		replace year = 1981 if regexm(iso3, "ZAF") & year == 1982 & dup == 1 
		recode dup (1=0) if regexm(iso3, "ZAF") & year == 1981
		drop if dup == 1 
		drop dup 

		expand 2, gen(dup)
		replace year = 1980 if regexm(iso3, "ZAF") & year == 1981 & dup == 1 
		recode dup (1=0) if regexm(iso3, "ZAF") & year == 1980
		drop if dup == 1 

		drop dup iso3 

		tempfile hiv_incidence
		save `hiv_incidence', replace 

		insheet using "`data_dir'/convert_to_new_age_ids.csv", comma names clear 
		merge 1:m age_group_id using `hiv_incidence', keep(3) nogen

		rename sex_id sex 
		rename age_start age 
		keep if age >= 15 & age <=80 & sex == 2 
		
		rename location_id iso3 

		renpfix inc incidence
		order incidence*, sequential

		forvalues i=1/1000 { 

			local new = `i' - 1 
			rename incidence`i' incidence`new'
		}

		keep iso3 year age sex incidence`draw_start'-incidence`draw_num'
		
		rename year_id year 

		tempfile hiv_incidence
		save `hiv_incidence', replace
	
// Loop through draws from best DisMod model for and calculate PAF for HIV incidence  
	forvalues d = `draw_start'/`draw_num' {
		di "DRAW `d'/`draw_num'"
		quietly {
				// Open dataset and pull only the current working draw	
					use iso3 year sex age draw_`d' sexnoncsw using `exposure', clear 
					
				// Linearly interpolate exposure and proportion HIV that is sexually transmitted (excluding commercial sex workers) between  year intervals
					reshape wide draw_`d' sexnoncsw, i(iso3 age sex) j(year)
					foreach y1 in 1980 1990 1995 2000 2005 2010 {
						// Assume both are constant for years between 1980 and 1990 since we have no information about the true trend
						if inlist(`y1', 1980) {
							forvalues x = 0/9 {
								local ynow = `y1' + `x'
								replace draw_`d'`ynow' = draw_`d'1990
								replace sexnoncsw`ynow' = sexnoncsw1990
							}
						}
						// Use linear trend between 5 year GBD intervals
						if inlist(`y1', 1990, 1995, 2000, 2005, 2010) {
							forvalues x = 1/4 {
								local y2 = `y1' + 5
								local ynow = `y1' + `x'
								replace draw_`d'`ynow' = exp(ln(draw_`d'`y1') + (ln(draw_`d'`y2') - ln(draw_`d'`y1'))*(`ynow'-`y1')/(`y2'-`y1'))
								replace sexnoncsw`ynow' = exp(ln(sexnoncsw`y1') + (ln(sexnoncsw`y2') - ln(sexnoncsw`y1'))*(`ynow'-`y1')/(`y2'-`y1'))
							}
						}
				
						}
					
								
					reshape long
					
				// Merge IPV exposure with relative risk
					gen x = 1
					merge m:1 x using "`rr_dir'/hiv_rr_draws.dta", keepusing(rr_`d') nogen
					
				// Calculate PAF on incidence  [Prevalence of IPV * (RR - 1)] / [Prevalence of IPV * (RR - 1) + 1]
					gen paf = (draw_`d' * (rr_`d'-1)) / (draw_`d' * (rr_`d'-1)+1)
				
				// Merge PAF on HIV incidence with HIV incidence dataset
					merge 1:1 iso3 year age sex using `hiv_incidence', nogen keep(match) keepusing(incidence`d')
					rename incidence`d' incidence
					
				// Only keep necessary variables
					keep iso3 year paf age sex sexnoncsw incidence
						
				// Apply proportion of HIV incidence that is sexually transmitted and not from CSW to total HIV incidence
					gen sexnoncsw_incidence = incidence * sexnoncsw
					drop sexnoncsw
					
				// Expand again to get 1 year age groups
					expand 5, gen(dup)
					bysort iso3 year age sex dup: gen y = _n
					forvalues x = 1/4 {
						replace age = age + y if y == `x' & dup == 1 
					}
					drop dup y	
				
				// Reshape wide	
					reshape wide incidence sexnoncsw_incidence paf, i(iso3 year sex) j(age)
					tostring year, replace
					replace year = "_" + year 
					reshape wide incidence* paf* sexnoncsw_incidence*, i(iso3 sex) j(year, string)	
					
				tempfile prepped
				save `prepped', replace
				
				
			// 1.) Denominator: Cumulative incidence of all HIV (after age start = 15, since 15 is our start age for estimating attributable IPV burden)		
				// Extract cumulative HIV incidence
				gen double prob1 = .
				gen double prob2 = .
				drop sexnoncsw_incidence*
					forvalues year = 1980/2015 {
						forvalues age_then = 15(1)84 {
							local age15yr = `year' - (`age_then' - 15)
							// Scenerio 1
							if `age15yr' < 1980 {
								local agein1980 = 1980 - (`age15yr'-15)
								replace prob1 = 1 - incidence`agein1980'_1980
								local agein1981 = `agein1980' + 1
								if `agein1981' < 84 {
									forvalues age = `agein1981'(1)`age_then' {
										local year = `age15yr' + (`age'-15)
										replace prob2 = prob1 * (1 - incidence`age'_`year')
										replace prob1 = prob2
									}
								}
							}
							// Scenerio 2
							if `age15yr' >= 1980 {
								replace prob1 = 1 - incidence15_`age15yr'
								if `age15yr' < `year' {
									forvalues age = 16(1)`age_then' {
										local year = `age15yr' + (`age'-15)
										replace prob2 = prob1 * (1 - incidence`age'_`year')
										replace prob1 = prob2
									}
								}
							}
								
							// Extract
								gen double prob_denominator`age_then'_`year' = prob1
						}
					}
						
				// Reshape long (twice) for later merge with the numerator cumulative probability
					drop incidence* paf* prob1 prob2
					// Reshape year long
						// save stubs in local
						if `d' == `draw_start' {
							local stublist1 = ""

							forvalues age = 15/84 {
								local stublist1 = "`stublist1' " + "prob_denominator`age'_"
							}	
						}

						reshape long "`stublist1'", i(iso3 sex) j(year)

					// Reshape age long
						reshape long prob_denominator, i(iso3 year sex) j(age, string)
						replace age = substr(age, 1, 2)
						destring age, replace
					
				// Cumulative incidence is 1 - probability of not getting HIV
					gen double denominator = 1 - prob_denominator	
					drop prob_denominator
					
				tempfile denominator
				save `denominator', replace
		
					
			// 2.) Numerator: Cumulative incidence of HIV due to IPV	
				use `prepped', clear
				gen double prob1 = .
				gen double prob2 = .
				drop incidence*
				// Extract cumulative HIV incidence
					forvalues year = 1980/2015 {
						forvalues age_then = 15(1)84 {
							local age15yr = `year' - (`age_then' - 15)
							// Scenerio 1
							if `age15yr' < 1980 {
								local agein1980 = 1980 - (`age15yr'-15)
								replace prob1 = 1 - (paf`agein1980'_1980 * sexnoncsw_incidence`agein1980'_1980) 
								local agein1981 = `agein1980' + 1
								if `agein1981' < 84 {
									forvalues age = `agein1981'(1)`age_then' {
										local year = `age15yr' + (`age'-15)
										replace prob2 = prob1 * (1 - (paf`age'_`year' * sexnoncsw_incidence`age'_`year'))
										replace prob1 = prob2
									}
								}
							}
							// Scenerio 2
							if `age15yr' >= 1980 {
								replace prob1 = 1 - (paf15_`age15yr' * sexnoncsw_incidence15_`age15yr')
								if `age15yr' < `year' {
									forvalues age = 16(1)`age_then' {
										local year = `age15yr' + (`age'-15)
										replace prob2 = prob1 * (1 - (paf`age'_`year' * sexnoncsw_incidence`age'_`year'))
										replace prob1 = prob2
									}
								}
							}
								
							// Extract
								gen double prob_numerator`age_then'_`year' = prob1
						}
					}
					
				// Reshape long (twice) for merge with denominator cumulative probability
					drop sexnoncsw_incidence* prob1 prob2
					// Reshape year long
						// save stubs in local (only need to do for first draw because local will be saved for use in following iterations)
						if `d' == `draw_start' {
							local stublist2 = ""

							forvalues age = 15/84 {
								local stublist2 = "`stublist2' " + "prob_numerator`age'_"
							}	
						}
						reshape long "`stublist2'", i(iso3 sex) j(year)
				
					// Reshape age long
						reshape long prob_numerator, i(iso3 year sex) j(age, string)
						replace age = substr(age, 1, 2)
						destring age, replace		
						
				// Cumulative incidence is 1 - probability of not getting HIV
					gen double numerator = 1 - prob_numerator		
					drop prob_numerator
		
				// Merge with prob_denominator
					merge 1:1 iso3 year age sex using `denominator', nogen
								
				// Calculate PAF on prevalence of HIV due to IDU
					gen draw_`d' = numerator / denominator
					recode draw_`d' (.=0) if numerator == 0 & denominator == 0
					drop numerator* denominator*
				
				// Keep only GBD years
					keep if inlist(year, 1990, 1995, 2000, 2005, 2010, 2015)

				// Take average of ages in each age group to get 5 year age group 
					forvalues gbdage = 15(5)80 {
						forvalues x = 1/4 {
							di `gbdage' + `x'
							replace age = age - `x' if age == (`gbdage' + `x')
						}
					}
					collapse (mean) draw_*, by(iso3 year age sex sex) fast

				// Save each draw as a tempfile to be appended at the end
					tempfile draw`d'
					save `draw`d'', replace
			}
		}
		
		// Merge 100 PAF draws for this parallelized chunk
			use `draw`draw_start'', clear
			local s = `draw_start' + 1
			forvalues d = `s'/`draw_num' {
				qui: merge 1:1 iso3 sex year age using `draw`d'', nogen
			}
			
		// Fill in identifying variables
			//gen acause = "hiv"
			//gen risk = "abuse_ipv_hiv"
			
		// Save in intermediate directory as country and sex specific files 
			cap mkdir "`out_dir'/`iso3'"
			save "`out_dir'/`iso3'/paf_draw_`iso3'_draw_`draw_start'.dta", replace
			
			

			
