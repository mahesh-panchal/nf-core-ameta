/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary log to screen
log.info logo + paramsSummaryLog(workflow) + citation

// WorkflowAmeta.initialise(params, log)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK } from '../subworkflows/local/input_check'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
// QC subworkflow
include { FASTQC as FASTQC_RAW        } from '../modules/nf-core/fastqc/main'
include { FASTQC as FASTQC_TRIM       } from '../modules/nf-core/fastqc/main'
include { CUTADAPT                    } from "$projectDir/modules/nf-core/cutadapt/main"

// Align subworkflow
include { BOWTIE2_BUILD       } from "$projectDir/modules/nf-core/bowtie2/build/main"
include { FASTQ_ALIGN_BOWTIE2 } from "$projectDir/subworkflows/nf-core/fastq_align_bowtie2/main"

// Krakenuniq subworkflow
include { KRAKENUNIQ_PRELOADEDKRAKENUNIQ } from "$projectDir/modules/nf-core/krakenuniq/preloadedkrakenuniq/"
include { KRAKENUNIQ_BUILD               } from "$projectDir/modules/nf-core/krakenuniq/build/main"
include { KRAKENUNIQ_FILTER              } from "$projectDir/modules/local/krakenuniq/filter"
include { KRAKENUNIQ_TOKRONA             } from "$projectDir/modules/local/krakenuniq/toKrona"
include { KRONA_KTUPDATETAXONOMY         } from "$projectDir/modules/nf-core/krona/ktupdatetaxonomy/main"
include { KRONA_KTIMPORTTAXONOMY         } from "$projectDir/modules/nf-core/krona/ktimporttaxonomy/main"
include { KRAKENUNIQ_ABUNDANCEMATRIX     } from "$projectDir/modules/local/krakenuniq/abundancematrix"

// Damage subworkflow
include { SAMTOOLS_VIEW } from "$projectDir/modules/nf-core/samtools/view/main"
include { MAPDAMAGE2    } from "$projectDir/modules/nf-core/mapdamage2/main"

// Malt subworkflow
include { MALT_PREPAREDB           } from "$projectDir/modules/local/malt/preparedb"
include { MALT_BUILD               } from "$projectDir/modules/nf-core/malt/build/main"
include { MALT_RUN                 } from "$projectDir/modules/nf-core/malt/run/main"
include { MALT_QUANTIFYABUNDANCE   } from "$projectDir/modules/local/malt/quantifyabundance"
include { MALT_ABUNDANCEMATRIXSAM  } from "$projectDir/modules/local/malt/abundancematrixsam"
include { MALT_ABUNDANCEMATRIXRMA6 } from "$projectDir/modules/local/malt/abundancematrixrma6"

// Authentic subworkflow
include { MALTEXTRACT            } from "$projectDir/modules/nf-core/maltextract/main"
include { SAMTOOLS_FAIDX         } from "$projectDir/modules/nf-core/samtools/faidx/main"
include { BREADTHOFCOVERAGE      } from "$projectDir/modules/local/breadthofcoverage"
include { READLENGTHDISTRIBUTION } from "$projectDir/modules/local/readlengthdistribution"
include { PMDTOOLS_SCORE         } from "$projectDir/modules/local/pmdtools/score"
include { PMDTOOLS_DEAMINATION   } from "$projectDir/modules/local/pmdtools/deamination"
include { AUTHENTICATIONPLOTS    } from "$projectDir/modules/local/authenticationplots"

// summary subworkflow

include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow AMETA {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        file(params.input)
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)
    // TODO: OPTIONAL, you can use nf-validation plugin to create an input channel from the samplesheet with Channel.fromSamplesheet("input")
    // See the documentation https://nextflow-io.github.io/nf-validation/samplesheets/fromSamplesheet/
    // ! There is currently no tooling to help you write a sample sheet schema

    //
    // SUBWORKFLOW: QC
    //
    FASTQC_RAW (
        INPUT_CHECK.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC_RAW.out.versions.first())
    CUTADAPT (
        INPUT_CHECK.out.reads
    )
    ch_versions = ch_versions.mix(CUTADAPT.out.versions.first())
    FASTQC_TRIM (
        CUTADAPT.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC_TRIM.out.versions.first())

    //
    // SUBWORKFLOW: ALIGN
    //
    ch_reference = Channel.fromPath( params.bowtie2_db, checkIfExists: true)
        .map{ file -> [ [ id: file.baseName ], file ] }
    BOWTIE2_BUILD( ch_reference )
    ch_versions = ch_versions.mix(BOWTIE2_BUILD.out.versions.first())
    FASTQ_ALIGN_BOWTIE2(
        CUTADAPT.out.reads,                   // ch_reads
        BOWTIE2_BUILD.out.index.collect(),    // ch_index
        false,                                // save unaligned
        false,                                // sort bam
        ch_reference.collect()                // ch_fasta
    )
    ch_versions = ch_versions.mix(FASTQ_ALIGN_BOWTIE2.out.versions)

    // SUBWORKFLOW: KRAKENUNIQ
    if( !params.krakenuniq_db ) {
        // TODO: Use Krakenuniq_Download to fetch taxonomy
        // TODO: Add to versions ch
        KRAKENUNIQ_BUILD (
            [   // Form input tuple.
                [ id: 'KrakenUniq_DB' ],
                file( params.krakenuniq_library_dir, checkIfExists: true ),
                file( params.krakenuniq_taxonomy_dir, checkIfExists: true ),
                file( params.krakenuniq_seq2taxid, checkIfExists: true )
            ]
        )
    }
    KRAKENUNIQ_PRELOADEDKRAKENUNIQ(
        CUTADAPT.out.reads,               // [ meta, fastqs ]
        params.krakenuniq_db ?
            Channel.fromPath(params.krakenuniq_db, checkIfExists: true ).collect() :
            KRAKENUNIQ_BUILD.out.db.collect{ it[1] }, // db
        params.krakenuniq_ram_chunk_size, // ram_chunk_size
        true,                             // save_output_reads
        true,                             // report_file
        true                              // save_output
    )
    KRAKENUNIQ_FILTER(
        KRAKENUNIQ_PRELOADEDKRAKENUNIQ.out.report,
        params.n_unique_kmers,
        params.n_tax_reads,
        file( params.pathogenomes_found, checkIfExists: true )
    )
    KRAKENUNIQ_TOKRONA(
        KRAKENUNIQ_FILTER.out.filtered.join(KRAKENUNIQ_PRELOADEDKRAKENUNIQ.out.classified_assignment)
    )
    KRONA_KTUPDATETAXONOMY()
    KRONA_KTIMPORTTAXONOMY(
        KRAKENUNIQ_TOKRONA.out.krona,
        params.krona_taxonomy_file ? file( params.krona_taxonomy_file, checkIfExists: true ) : KRONA_KTUPDATETAXONOMY.out.db
    )
    KRAKENUNIQ_ABUNDANCEMATRIX(
        KRAKENUNIQ_FILTER.out.filtered.collect{ it[1] },
        params.n_unique_kmers,
        params.n_tax_reads
    )

    // SUBWORKFLOW: Map Damage
    Channel.fromPath( params.bowtie2_seqid2taxid_db, checkIfExists: true )
        .flatMap{ tsv -> tsv.splitCsv(header:false, sep:"\t")*.reverse() }
        .groupTuple() // [ taxid, [ ref1, ref2, ref3 ] ]
        .combine( KRAKENUNIQ_FILTER.out.species_tax_id.flatMap{ meta, txt -> txt.splitText().collect{ [ it.trim(), meta ] } }, by: 0 )
            // Don't need to collectFile. Just pass the list to $args2
        // .collectFile(){ taxid, refs, meta -> [ "${meta.id}.${taxid}.seqids", refs.join('\n') ] }
        // .map { file -> [ file.name.split('.')[0], file ] } // meta_id, refs file
        .map { taxid, seqids, meta -> [ meta, taxid, seqids ] }
        .combine( FASTQ_ALIGN_BOWTIE2.out.bam.join(FASTQ_ALIGN_BOWTIE2.out.bai), by: 0 )
        // Add taxid and seqids to meta so $args2 can reference it
        .map { meta, taxid, seqids, bam, bai -> [ meta + [ taxid: taxid, seqids: seqids ], bam, bai ] }
        .set{ ch_taxid_seqrefs }
    SAMTOOLS_VIEW (
        ch_taxid_seqrefs, // bam files
        [ [] , [] ],      // Empty fasta reference
        []                // Empty qname file
    )
    // FASTQ_ALIGN_BOWTIE2.out.bam.join( KRAKENUNIQ_FILTER.out.species_tax_id )
    MAPDAMAGE2 (
        SAMTOOLS_VIEW.out.bam, // bams
        ch_reference.collect{ it[1] } // fasta
    )

    // SUBWORKFLOW: Malt
    MALT_PREPAREDB (
        KRAKENUNIQ_ABUNDANCEMATRIX.out.species_taxid_list,
        file(params.malt_seqid2taxid_db, checkIfExists: true),
        file(params.malt_nt_fasta, checkIfExists: true)
    )
    MALT_BUILD ( // What is the accession2taxid arg?
        MALT_PREPAREDB.out.library,
        [],
        file(params.malt_accession2taxid, checkIfExists: true) // Note: Deprecated. Should be replaced with Megan db.
    )
    MALT_RUN (
        CUTADAPT.out.reads,
        MALT_BUILD.out.index.collect(),
        'BlastN'
    )
    MALT_QUANTIFYABUNDANCE (
        MALT_RUN.out.alignments,
        KRAKENUNIQ_ABUNDANCEMATRIX.out.species_taxid_list.collect()
    )
    MALT_ABUNDANCEMATRIXSAM ( MALT_QUANTIFYABUNDANCE.out.counts.collect{ it[1] } )
    MALT_ABUNDANCEMATRIXRMA6 ( MALT_RUN.out.rma6.collect{ it[1] } )

    // SUBWORKFLOW: authentic
    // Create sample taxid directories // TODO Do I need this?
    // MAKENODELIST() // TODO meta
    // MALTEXTRACT(
    //     MALT_RUN.out.rma6,
    //     MAKENODELIST.out.node_list, // Join?
    //     file(params.ncbi_dir, checkIfExists: true)
    // )
    // SAMTOOLS_FAIDX( ch_reference.map{ file -> [ [ id: file.baseName ], file ] } ) // TODO check: Should be malt_nt
    // malt_nt_fasta = ch_reference.join(SAMTOOLS_FAIDX.out.fai).multiMap { meta, fasta, fai ->
    //         fasta: fasta
    //         fai  : fai
    //     }
    // BREADTHOFCOVERAGE(
    //     MALT_RUN.out.alignments,
    //     malt_nt_fasta.fasta.collect(),
    //     malt_nt_fasta.fai.collect(),
    // )
    // READLENGTHDISTRIBUTION(BREADTHOFCOVERAGE.out.sorted_bam)
    // PMDTOOLS_SCORE(BREADTHOFCOVERAGE.out.sorted_bam)
    // PMDTOOLS_DEAMINATION(BREADTHOFCOVERAGE.out.sorted_bam)
    // AUTHENTICATIONPLOTS(
    //     node_list // TODO
    //     .join(READLENGTHDISTRIBUTION.out.read_length)
    //     .join(PMDTOOLS_SCORE.out.pmd_scores)
    //     .join(BREADTHOFCOVERAGE.out.breadth_of_coverage)
    // )
    // ch_authentication_score = MALT_RUN.out.rma6
    //     .join(MALTEXTRACT.out.results)
    //     .join(BREADTHOFCOVERAGE.out.name_list)
    //     .multiMap { meta, rma6, maltex_dir, name_list ->
    //         rma6: [ meta, rma6 ]
    //         maltex_dir: maltex_dir
    //         name_list: name_list
    // }
    // AUTHENTICATIONSCORE(
    //     ch_authentication_score // 3 channels
    // )

    // SUBWORKFLOW: summary

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowAmeta.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowAmeta.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_RAW.out.zip.map { m, zip -> zip })
    ch_multiqc_files = ch_multiqc_files.mix(CUTADAPT.out.log.map { m, log -> log })
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_TRIM.out.zip.map { m, zip -> zip })
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
