import os
import re
from snakemake.utils import min_version

##### set minimum snakemake version #####
min_version("5.1.4")

##### load config file and sample list #####
configfile: "config.yaml"

##### list of input samples #####
samples = [key for key in config['reads']]

##### prefix for phylogenetic tree and SNV distance files #####
if config['prefix'] is None:
	prefix = re.split("/|\.", config['reference'])[-2]
else:
	prefix = config['prefix']

##### rules #####

# index reference genome for bwa alignment
rule bwa_index:
	input: config['reference']
	output:
		"{ref}.amb".format(ref=config['reference']),
		"{ref}.ann".format(ref=config['reference']),
		"{ref}.bwt".format(ref=config['reference']),
		"{ref}.pac".format(ref=config['reference']),
		"{ref}.sa".format(ref=config['reference'])
	resources:
		mem=2,
		time=1
	shell:
		"bwa index {input}"

# align reads to reference genome with bwa
rule bwa_align:
	input:
		ref_index = rules.bwa_index.output,
		r = lambda wildcards: config["reads"][wildcards.sample]
	output:
		"filtered_bam/{sample}.filtered.bam"
	resources:
		mem=32,
		time=6
	threads: 8
	params:
		ref = config['reference'],
		qual=config['mapq'],
		nm=config['n_mismatches']
	shell:
		"bwa mem -t {threads} {params.ref} {input.r} | "\
		"samtools view -b -q {params.qual} | "\
		"bamtools filter -tag 'NM:<={params.nm}' | "\
		"samtools sort --threads {threads} -o {output}"

# count base read coverage
rule genomecov:
	input:
		rules.bwa_align.output
	output:
		"genomecov/{sample}.tsv"
	resources:
		mem=8,
		time=1,
	threads: 1
	shell:
		"bedtools genomecov -ibam {input} > {output}"

# calculate average coverage across the genome
rule calc_coverage:
	input:
		rules.genomecov.output
	output:
		"coverage/{sample}.cvg"
	resources:
		mem=8,
		time=1,
	threads: 1
	params:
		cvg=config['min_cvg']
	script:
		"scripts/getCoverage.py"

# filter samples that meet coverage requirements
rule filter_samples:
	input: expand("coverage/{sample}.cvg", sample = samples)
	output:
		dynamic("passed_samples/{sample}.bam")
	resources:
		mem=1,
		time=1
	threads: 1
	params:
		min_cvg=config['min_cvg'],
		min_perc=config['min_genome_percent']
	run:
		samps = input
		for samp in samps:
			with open(samp) as s:
				cvg, perc = s.readline().rstrip('\n').split('\t')
			if (float(cvg) >= params.min_cvg and float(perc) > params.min_perc):
				shell("ln -s $PWD/filtered_bam/{s}.filtered.bam passed_samples/{s}.bam".format(s=os.path.basename(samp).rstrip(".cvg")))

# index reference genome for pileup
rule faidx:
	input: config['reference']
	output: "{ref}.fai".format(ref=config['reference'])
	resources:
		mem=2,
		time=1
	shell:
		"samtools faidx {input}"

# create pileup from bam files
rule pileup:
	input:
		bam="passed_samples/{sample}.bam",
		ref=config['reference'],
		index=rules.faidx.output
	output: "pileup/{sample}.pileup"
	resources:
		mem=32,
		time=1
	threads: 16
	shell:
		"samtools mpileup -f {input.ref} -B -aa -o {output} {input.bam}"

# call SNPs from pileup
rule call_snps:
	input: rules.pileup.output
	output: "snp_calls/{sample}.tsv"
	resources:
		mem=32,
		time=2
	threads: 16
	params:
		min_cvg=5,
		min_freq=0.8,
		min_qual=20
	script:
		"scripts/callSNPs.py"

# get consensus sequence from pileup
rule snp_consensus:
	input: rules.call_snps.output
	output: "consensus/{sample}.txt"
	resources:
		mem=2,
		time=2
	threads: 1
	shell:
		"echo {wildcards.sample} > {output}; cut -f4 {input} >> {output}"

# combine consensus sequences into one file
rule combine:
	input:
		dynamic("consensus/{sample}.txt")
	output: "{name}.cns.tsv".format(name = prefix)
	resources:
		mem=2,
		time=1
	threads: 1
	shell:
		"paste {input} > {output}"

# find positions that have a base call in each input genome and at least
# one variant in the set of input genomes
rule core_snps:
	input: rules.combine.output
	output: "{name}.core_snps.tsv".format(name = prefix)
	resources:
		mem=16,
		time=1
	threads: 1
	script:
		"scripts/findCoreSNPs.py"

# convert core SNPs file to fasta format
rule core_snps_to_fasta:
	input: rules.core_snps.output
	output: "{name}.fasta".format(name = prefix)
	resources:
		mem=16,
		time=1
	threads: 1
	script:
		"scripts/coreSNPs2fasta.py"

# perform multiple sequence alignment of fasta file
rule multi_align:
	input: rules.core_snps_to_fasta.output
	output: "{name}.afa".format(name = prefix)
	resources:
		mem=200,
		time=12
	threads: 1
	shell:
		"muscle -in {input} -out {output}"

# calculate phylogenetic tree from multiple sequence alignment
rule build_tree:
	input: rules.multi_align.output
	output: "{name}.tree".format(name = prefix)
	resources:
		mem=8,
		time=1
	threads: 1
	shell:
		"fasttree -nt {input} > {output}"

# plot phylogenetic tree
rule plot_tree:
	input: rules.build_tree.output
	output: "{name}.tree.pdf".format(name = prefix)
	resources:
		mem=8,
		time=1
	threads: 1
	script:
		"scripts/renderTree.R"

# count pairwise SNVs between input samples
rule pairwise_snvs:
	input: dynamic("consensus/{sample}.txt")
	output: "{name}.dist.tsv".format(name = prefix)
	resources:
		mem=8,
		time=1
	threads: 1
	script:
		"scripts/pairwiseDist.py"
