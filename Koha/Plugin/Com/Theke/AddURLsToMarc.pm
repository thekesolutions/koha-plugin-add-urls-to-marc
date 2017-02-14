package Koha::Plugin::Com::Theke::AddURLsToMarc;

use Modern::Perl;
use utf8;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Biblio qw/GetMarcBiblio ModBiblio GetFrameworkCode/;
use C4::Context;

use Koha::Biblios;
use Koha::Items;
use Koha::Upload;

use MARC::Record;
use MARC::Field;
use Text::CSV;

our $VERSION = 1.3;

our $metadata = {
    name            => 'Add URLs to MARC records',
    author          => 'Tomás Cohen Arazi',
    description     => 'Tool for importing URLs into MARC records',
    date_authored   => '2016-10-17',
    date_updated    => '2016-10-17',
    minimum_version => undef,
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my $step = $cgi->param('step') // 'welcome';

    if ( $step eq 'welcome' ) {
        $self->tool_step_welcome;
    }
    elsif ( $step eq 'results' ) {
        $self->tool_step_results;
    }
    elsif ( $step eq 'diff' ) {
        $self->show_diff;
    }
    elsif ( $step eq 'cancel' ) {
        $self->tool_step_cancel;
    }
    elsif ( $step eq 'apply' ) {
        $self->tool_step_apply;
    }
    else {
        # $step eq 'render'
        $self->tool_step_results;
    }
}

sub tool_step_welcome {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool-step-welcome.tt' } );

    if ( $args->{'error'} ) {
        $template->param( error => $args->{'error'} );
    }

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub tool_step_results {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template;

    my $id  = $cgi->param('uploadedfileid');
    my $rec = Koha::Upload->new->get( { id => $id, filehandle => 1 } );
    my $fh  = $rec->{fh};

    my @good_rows;
    my @bad_rows;

    my $csv = Text::CSV->new( { binary => 1 } )    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();
    $csv->column_names(qw( biblionumber url text ));
    $csv->getline_hr($fh);                         #drop the first line

    while ( my $row = $csv->getline_hr($fh) ) {
        my $result
            = { biblionumber => $row->{biblionumber}, url => $row->{url}, text => $row->{text} };
        my $biblio = Koha::Biblios->find( $row->{biblionumber} );
        $result->{title} = ( defined $biblio ) ? $biblio->title : '';

        if ($biblio) {
            push @good_rows, $result;
        }
        else {
            push @bad_rows, $result;
        }
    }
    $csv->eof or $csv->error_diag();
    close $fh;

    $template = $self->get_template( { file => 'tool-step-results.tt' } );
    $template->param(
        good_rows      => \@good_rows,
        bad_rows       => \@bad_rows,
        uploadedfileid => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub tool_step_apply {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template;

    my $id  = $cgi->param('uploadedfileid');
    my $rec = Koha::Upload->new->get( { id => $id, filehandle => 1 } );
    my $fh  = $rec->{fh};

    my @biblios;
    my @bad_rows;

    my $csv = Text::CSV->new( { binary => 1 } )    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();
    $csv->column_names(qw( biblionumber url text ));
    $csv->getline_hr($fh);                         #drop the first line

    while ( my $row = $csv->getline_hr($fh) ) {
        my $result
            = { biblionumber => $row->{biblionumber}, url => $row->{url}, text => $row->{text} };
        my $biblio = Koha::Biblios->find( $row->{biblionumber} );

        if ($biblio) {
            # Get the MARC record as Koha does
            my $record          = GetMarcBiblio( $biblio->biblionumber );
            my $fw              = GetFrameworkCode( $biblio->biblionumber );
            my $modified_record = $record->clone();
            _add_url( $modified_record, $row->{url}, $row->{text} );
            ModBiblio( $modified_record, $biblio->biblionumber, $fw );
            push @biblios, $biblio;
        }
        else {
            push @bad_rows, $result;
        }
    }

    $csv->eof or $csv->error_diag();
    close $fh;
    Koha::Upload->new->delete( { id => $id, filehandle => 1 } );

    $template = $self->get_template( { file => 'tool-step-final.tt' } );
    $template->param(
        good_rows      => undef,
        bad_rows       => \@bad_rows,
        uploadedfileid => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub tool_step_cancel {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $id = $cgi->param('uploadedfileid');

    Koha::Upload->new->delete( { id => $id } )
        if defined $id;

    my $template = $self->get_template( { file => 'tool-step-welcome.tt' } );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub show_diff {

    my $self = shift;
    my $cgi  = $self->{cgi};

    my $biblionumber = $cgi->param('biblionumber');
    my $url          = $cgi->param('url');
    my $text         = $cgi->param('text');
    my $id           = $cgi->param('uploadedfileid');

    my $record          = GetMarcBiblio($biblionumber);
    my $modified_record = $record->clone();
    _add_url( $modified_record, $url, $text );

    my $template = $self->get_template( { file => 'marc-diff.tt' } );
    $template->param(
        BIBLIONUMBER    => $biblionumber,
        MARC_FORMATTED1 => $record->as_formatted,
        MARC_FORMATTED2 => $modified_record->as_formatted,
        uploadedfileid  => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();

}

sub _add_url {
    my ( $record, $url, $text ) = @_;
    my $ind1 = ( $url =~ m/^http/ ) ? 4 : '';
    my $field = MARC::Field->new( '856', $ind1, '', u => $url, y => $text );
    $record->insert_fields_ordered($field);
}

1;
