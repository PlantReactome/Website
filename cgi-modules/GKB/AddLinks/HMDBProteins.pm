
=head1 NAME

GKB::AddLinks::HmdbProteins

=head1 SYNOPSIS

=head1 DESCRIPTION

Adds HMDB linkers to ReferenceProteins having chebi-IDs

=head1 SEE ALSO

GKB::DBAdaptor

=head1 AUTHOR

Sheldon McKay <lt>sheldon.mckay@gmail.com<gt>

Copyright (c) 2014 Ontario Institure for Cancer Research

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  See DISCLAIMER for
disclaimers of warranty.

=cut

package GKB::AddLinks::HMDBProteins;
use strict;

use GKB::Config;
use GKB::AddLinks::Builder;
use GKB::HMDB;

use Log::Log4perl qw/get_logger/;
Log::Log4perl->init(\$LOG_CONF);

use vars qw(@ISA $AUTOLOAD %ok_field);
use Data::Dumper;

@ISA = qw(GKB::AddLinks::Builder);

sub AUTOLOAD {
    my $self = shift;
    my $attr = $AUTOLOAD;
    $attr =~ s/.*:://;
    return unless $attr =~ /[^A-Z]/;    # skip DESTROY and all-cap methods
    $self->throw("invalid attribute method: ->$attr()") unless $ok_field{$attr};
    $self->{$attr} = shift if @_;
    return $self->{$attr};
}

sub new {
    my ($pkg) = @_;

    # Get class variables from superclass and define any new ones
    # specific to this class.
    $pkg->get_ok_field();

    my $self = $pkg->SUPER::new();
    return $self;
}

sub mapper {
    my $self = shift;
    my $dba = shift;
    if ($dba) {
	$self->{mapper} = GKB::HMDB->new($dba);
    }
    return $self->{mapper};
}

# Needed by subclasses to gain access to object variables defined in
# this class.
sub get_ok_field {
    my ($pkg) = @_;

    %ok_field = $pkg->SUPER::get_ok_field();

    return %ok_field;
}

sub buildPart {
    my $self = shift;

    my $logger = get_logger(__PACKAGE__);
    
    my $pkg = __PACKAGE__;

    $logger->info("entered\n");

    $self->timer->start( $self->timer_message );
    my $dba = $self->builder_params->refresh_dba();
    $dba->matching_instance_handler(
        new GKB::MatchingInstanceHandler::Simpler );

    my $mapper = $self->mapper($dba);

    # A hash where the keys are HMDB Ids and the values are GKInstances
    my $proteins = $mapper->fetch_proteins();

    my $attribute = 'crossReference';
    $self->set_instance_edit_note("${attribute}s inserted by $pkg");

    # get a unique list of ReferenceProtein instances
    my %instances;
    for my $group (values %$proteins) {
	my @proteins = @$group;
	for my $protein (@proteins) {
	    next unless $protein && ref $protein;
	    $instances{$protein->db_id} = $protein;
	}
    }
    my $instances = [values %instances];

    # Load the values of an attribute to be updated. Not necessary for the 1st time though.
    $dba->load_class_attribute_values_of_multiple_instances(
        'DatabaseIdentifier', 'identifier', $instances );

    my $hmdb_ref_db =
      $self->builder_params->reference_database->get_hmdb_protein_reference_database();

    while (my ($hmdb,$proteins) = each %$proteins) {
        $logger->info("i->Identifier=HMDB:$hmdb\n");

	for my $protein (@$proteins) { 
	    $protein || next;
	    $logger->info("I am working on ReferenceProtein " . $protein->db_id());
	    ## Careful! ReferenceProteins can be associated with > 1 HMDB ID.
	    ## Only do this the first time the instance is encountered!
	    unless ( $self->{seen}->{$protein->db_id()}++ ) {
		$self->remove_typed_instances_from_attribute( $protein, $attribute,
							      $hmdb_ref_db );
	    }
	    
	    my $hmdb_database_identifier = $self->builder_params->database_identifier
		->get_hmdb_protein_database_identifier( $hmdb );
	    $protein->add_attribute_value( $attribute, $hmdb_database_identifier );
	    $dba->update_attribute( $protein, $attribute );
	    $protein->add_attribute_value( 'modified', $self->instance_edit );
	    $dba->update_attribute( $protein, 'modified' );
	    $self->increment_insertion_stats_hash( $protein->db_id() );
	}
    }

    $self->print_insertion_stats_hash();

    $self->timer->stop( $self->timer_message );
    $self->timer->print();
}

1;

