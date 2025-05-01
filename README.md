Processing of public metagenomic data that has been analysed with SingleM.

Most code here is not intended for public usage as many paths etc are specific to CMR / QUT / Woodcroft group, but nonetheless may be useful for others.

# Post-processing a singlem renew run of SRA data

First modify paths at the top of the Snakemake
    
Then setup:
```
pixi install --all
```

and run
```
pixi run snakemake --cores 1
```

Make sure the correct taxonomic level is chosen for applying predictions in the Snakemake file. See 
`{base_output_directory}/logs/host_or_not_prediction.log` for the results of the cross validation.

# Host-vs-not metagenome prediction

Example code for host-vs-not prediction is contained within the `Snakefile`. In 