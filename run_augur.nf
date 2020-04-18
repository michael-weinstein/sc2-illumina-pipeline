def helpMessage() {
  log.info"""
    Pipeline for running augur commands to build auspice visualization from main output.

    Usage:

    Mandatory arguments:
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.
      --sequences                   FASTA file of consensus sequences from main output
      --metadata                    TSV of metadata from main output
      --ref_gb                      Reference Genbank file for augur
      --nextstrain_sequences        FASTA of sequences to build a tree with
      --minLength                   Minimum base pair length to allow assemblies to pass QC

    Nextstrain options:
      --nextstrain_ncov             Path to nextstrain/ncov directory (default: fetches from github)
      --subsample  N                Subsample nextstrain sequences to N (set to false if no subsampling, default: 100)

    Other options:
      --outdir                      The output directory where the results will be saved
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      -resume                       Use cached results

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}


// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

ref_gb = file(params.ref_gb, checkIfExists: true)

nextstrain_sequences_ch = Channel.from(file(params.nextstrain_sequences, checkIfExists: true))

nextstrain_ncov = params.nextstrain_ncov
if (nextstrain_ncov[-1] != "/") {
    nextstrain_ncov = nextstrain_ncov + "/"
}

nextstrain_metadata_path = file(nextstrain_ncov + "data/metadata.tsv", checkIfExists: true)
nextstrain_config = nextstrain_ncov + "config/"
include_file = file(nextstrain_config + "include.txt", checkIfExists: true)
exclude_file = file(nextstrain_config + "exclude.txt", checkIfExists: true)
clades = file(nextstrain_config + "clades.tsv", checkIfExists: true)
auspice_config = file(nextstrain_config + "auspice_config.json", checkIfExists: true)
lat_longs = file(nextstrain_config + "lat_longs.tsv", checkIfExists: true)

process prepareSequences {

    input:
    path(nextstrain_sequences) from nextstrain_sequences_ch

    output:
    path('subsampled_sequences.fasta') into nextstrain_subsampled_ch

    script:
    if (params.subsample)
    """
    seqtk sample -s 11 ${nextstrain_sequences} ${params.subsample} > subsampled_sequences.fasta
    seqkit faidx -r ${nextstrain_sequences} '.+Wuhan-Hu-1/2019.+' >> subsampled_sequences.fasta
    """
    else
    """
    cp ${nextstrain_sequences} subsampled_sequences.fasta
    """
}

process makeNextstrainInput {
    publishDir "${params.outdir}/nextstrain/data", mode: 'copy'
    stageInMode 'copy'

    input:
    path(sample_sequences) from nextstrain_ch
    path(nextstrain_sequences) from nextstrain_subsampled_ch
    path(nextstrain_metadata_path)
    path(included_samples) from included_samples_ch
    path(included_fastas) from included_fastas_ch
    path(include_file)

    output:
    path('metadata.tsv') into (nextstrain_metadata, refinetree_metadata, infertraits_metadata, tipfreq_metadata, export_metadata)
    path('deduped_sequences.fasta') into nextstrain_sequences
    path('included_sequences.txt') into nextstrain_include

    script:
    currdate = new java.util.Date().format('yyyy-MM-dd')
    // Normalize the GISAID names using Nextstrain's bash script
    """
    make_nextstrain_input.py -ps ${nextstrain_sequences} -pm ${nextstrain_metadata_path} -ns ${sample_sequences} --date $currdate \
    -r 'North America' -c USA -div 'California' -loc 'San Francisco County' -origlab 'Biohub' -sublab 'Biohub' \
    -subdate $currdate

    normalize_gisaid_fasta.sh all_sequences.fasta sequences.fasta
    cat ${included_samples} ${include_file} > included_sequences.txt
    cat ${included_fastas} >> sequences.fasta
    seqkit rmdup sequences.fasta > deduped_sequences.fasta
    """

}

process filterStrains {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(sequences) from nextstrain_sequences
    path(metadata) from nextstrain_metadata
    path(include_file) from nextstrain_include
    path(exclude_file)

    output:
    path('filtered.fasta') into filtered_sequences_ch

    script:
    String exclude_where = "date='2020' date='2020-01-XX' date='2020-02-XX' date='2020-03-XX' date='2020-04-XX' date='2020-01' date='2020-02' date='2020-03' date='2020-04'"
    """
    augur filter \
            --sequences ${sequences} \
            --metadata ${metadata} \
            --include ${include_file} \
            --exclude ${exclude_file} \
            --exclude-where ${exclude_where} \
            --min-length ${params.minLength} \
            --output filtered.fasta
    """
}

process alignSequences {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    cpus 4

    input:
    path(filtered_sequences) from filtered_sequences_ch
    path(ref_fasta)

    output:
    path('aligned.fasta') into (aligned_ch, refinetree_alignment, ancestralsequences_alignment)


    script:
    """
    augur align \
        --sequences ${filtered_sequences} \
        --reference-sequence ${ref_fasta} \
        --output aligned.fasta \
        --nthreads ${task.cpus} \
        --remove-reference \
        --fill-gaps
    """
}

process buildTree {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    cpus 4

    input:
    path(alignment) from aligned_ch

    output:
    path("tree_raw.nwk") into tree_raw_ch

    script:
    """
    augur tree \
        --method fasttree \
        --alignment ${alignment} \
        --output tree_raw.nwk \
        --nthreads ${task.cpus}
    """
}

process refineTree {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(tree) from tree_raw_ch
    path(alignment) from refinetree_alignment
    path(metadata) from refinetree_metadata

    output:
    path('tree.nwk') into (ancestralsequences_tree, translatesequences_tree, infertraits_tree, addclades_tree, tipfreq_tree, export_tree)
    path('branch_lengths.json') into export_branch_lengths

    script:
    """
    augur refine \
        --tree ${tree} \
        --alignment ${alignment} \
        --metadata ${metadata} \
        --output-tree tree.nwk \
        --output-node-data branch_lengths.json \
        --root 'Wuhan-Hu-1/2019' \
        --timetree \
        --clock-rate 0.0008 \
        --clock-std-dev 0.0004 \
        --coalescent skyline \
        --date-inference marginal \
        --divergence-unit mutations \
        --date-confidence \
        --no-covariance \
        --clock-filter-iqd 4
    """
}

process ancestralSequences {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(tree) from ancestralsequences_tree
    path(alignment) from ancestralsequences_alignment

    output:
    path('nt_muts.json') into (translatesequences_nodes, addclades_nuc_muts, export_nt_muts)

    script:
    """
    augur ancestral \
        --tree ${tree} \
        --alignment ${alignment} \
        --output-node-data nt_muts.json \
        --inference joint \
        --infer-ambiguous
    """
}

process translateSequences {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(tree) from translatesequences_tree
    path(nodes) from translatesequences_nodes
    path(ref_gb)

    output:
    path('aa_muts.json') into (addclades_aa_muts, export_aa_muts)

    script:
    """
    augur translate \
        --tree ${tree} \
        --ancestral-sequences ${nodes} \
        --reference-sequence ${ref_gb} \
        --output-node-data aa_muts.json \
    """
}


process inferTraits {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(tree) from infertraits_tree
    path(metadata) from infertraits_metadata

    output:
    path('traits.json') into export_traits

    script:
    """
    augur traits \
        --tree ${tree} \
        --metadata ${metadata} \
        --output traits.json \
        --columns country_exposure \
        --confidence \
        --sampling-bias-correction 2.5 \
    """
}

process addClades {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/results", mode: 'copy'

    input:
    path(tree) from addclades_tree
    path(aa_muts) from addclades_aa_muts
    path(nuc_muts) from addclades_nuc_muts
    path(clades)

    output:
    path('clades.json') into export_clades

    script:
    """
    augur clades --tree ${tree} \
        --mutations ${nuc_muts} ${aa_muts} \
        --clades ${clades} \
        --output-node-data clades.json
    """
}

process tipFrequencies {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/auspice", mode: 'copy'

    input:
    path(tree) from tipfreq_tree
    path(metadata) from tipfreq_metadata

    output:
    path('ncov_tip-frequencies.json')

    script:
    """
    augur frequencies \
        --method kde \
        --metadata ${metadata} \
        --tree ${tree} \
        --min-date 2020.0 \
        --pivot-interval 1 \
        --narrow-bandwidth 0.05 \
        --proportion-wide 0.0 \
        --output ncov_tip-frequencies.json
    """
}

process exportData {
    label 'nextstrain'
    publishDir "${params.outdir}/nextstrain/auspice", mode: 'copy'

    input:
    path(tree) from export_tree
    path(metadata) from export_metadata
    path(branch_lengths) from export_branch_lengths
    path(nt_muts) from export_nt_muts
    path(aa_muts) from export_aa_muts
    path(traits) from export_traits
    path(auspice_config)
    path(lat_longs)
    path(clades) from export_clades

    output:
    path('ncov.json')

    script:
    """
    augur export v2 \
        --tree ${tree} \
        --metadata ${metadata} \
        --node-data ${branch_lengths} ${nt_muts} ${aa_muts} ${traits} ${clades} \
        --auspice-config ${auspice_config} \
        --lat-longs ${lat_longs} \
        --output ncov.json
    """
}
