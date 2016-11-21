import os
import sys
import yaml
import importlib
from lcdblib.utils.imports import resolve_name
from lcdblib.snakemake import aligners, helpers
from common import download_and_postprocess


def wrapper_for(path):
    return os.path.join('file://', str(srcdir('.')), '..', 'wrappers', 'wrappers', path)


references_dir = config['references_dir']
if not os.path.exists(references_dir):
    os.makedirs(references_dir)


# Map "indexes" value to a pattern specific to each index.
index_extensions = {
    'bowtie2': aligners.bowtie2_index_from_prefix(''),
    'hisat2': aligners.hisat2_index_from_prefix(''),
    'kallisto': ['.idx'],
}

}

references_targets = []

for block in config['references']:
    # e.g.,
    #
    #   references_dir: /data/refs
    #   -
    #       assembly: hg19
    #       tag: gencode-v25
    #       type: gtf
    #       url: ...
    #
    # will add the following to targets:
    #
    #   /data/refs/hg19/gtf/hg19_gencode-v25.gtf
    #
    tag = block.get('tag', 'default')
    references_targets.append(
        '{references_dir}/'
        '{block[assembly]}/'
        '{block[type]}/'
        '{block[assembly]}_{tag}.{block[type]}'.format(**locals())
    )


    if block['type'] == 'fasta':
        # Add indexes if specified
        indexes = block.get('indexes', [])
        for index in indexes:
            ext = index_extensions[index]
            references_targets += expand(
                '{references_dir}/{assembly}/{index}/{assembly}_{tag}{ext}',
                references_dir=references_dir, assembly=block['assembly'], index=index, tag=tag, ext=ext
            )

        # Add chromsizes
        references_targets.append(
            '{references_dir}/'
            '{block[assembly]}/'
            '{block[type]}/'
            '{block[assembly]}_{tag}.chromsizes'.format(**locals())
        )

rule all_references:
    input: references_targets


# Downloads the configured URL, applies any configured post-processing, and
# saves the resulting gzipped file to *.fasta.gz or *.gtf.gz.
rule download_and_process:
    output: temporary('{references_dir}/{assembly}/{_type}/{assembly}_{tag}.{_type}.gz')
    run:
        download_and_postprocess(output[0], config, wildcards.assembly, wildcards.tag)


rule unzip:
    input: rules.download_and_process.output
    output: '{references_dir}/{assembly}/{_type}/{assembly}_{tag}.{_type}'
    shell: 'gunzip -c {input} > {output}'


rule bowtie2_index:
    output: index=aligners.bowtie2_index_from_prefix('{references_dir}/{assembly}/bowtie2/{assembly}_{tag}')
    input: fasta='{references_dir}/{assembly}/fasta/{assembly}_{tag}.fasta'
    log: '{references_dir}/{assembly}/bowtie2/{assembly}_{tag}.log'
    wrapper: wrapper_for('bowtie2/build')


rule hisat2_index:
    output: index=aligners.hisat2_index_from_prefix('{references_dir}/{assembly}/hisat2/{assembly}_{tag}')
    input: fasta='{references_dir}/{assembly}/fasta/{assembly}_{tag}.fasta'
    log: '{references_dir}/{assembly}/hisat2/{assembly}_{tag}.log'
    wrapper: wrapper_for('hisat2/build')


rule kallisto_index:
    output: '{references_dir}/{assembly}/kallisto/{assembly}_{tag}.idx'
    input: '{references_dir}/{assembly}/{assembly}{tag}.fa.gz'
    log: '{references_dir}/{assembly}/kallisto/{assembly}{tag}.log'
    shell:
        '''
        kallisto index -i {output} --make-unique {input} > {log} 2> {log}
        '''

rule chromsizes:
    output: '{references_dir}/{assembly}/fasta/{assembly}_{tag}.chromsizes'
    input: '{references_dir}/{assembly}/fasta/{assembly}_{tag}.fasta'
    shell:
        'rm -f {output}.tmp '
        '&& picard CreateSequenceDictionary R={input} O={output}.tmp '
        '&& grep "^@SQ" {output}.tmp '
        '''| awk '{{print $2, $3}}' '''
        '| sed "s/SN://g;s/ LN:/\\t/g" > {output} '
        '&& rm -f {output}.tmp '

# vim: ft=python