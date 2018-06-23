package Koha::Plugin::Com::Theke::AddURLsToMarc;

use Modern::Perl;
use utf8;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Biblio qw/GetMarcBiblio ModBiblio GetFrameworkCode/;
use C4::Context;

use Koha::Biblios;
use Koha::Items;
use Koha::UploadedFiles;

use MARC::Record;
use MARC::Field;
use Text::CSV;

our $VERSION = "{VERSION}";

our $metadata = {
    name            => 'Add URLs to MARC records',
    author          => 'Tomás Cohen Arazi',
    description     => 'Tool for importing URLs into MARC records',
    date_authored   => '2016-10-17',
    date_updated    => '2016-10-17',
    minimum_version => '17.1100000',
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
        # $self->tool_step_results;
        $self->tool_step_results;
    }
    elsif ( $step eq 'diff' ) {
        #$self->show_diff;
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

    my $template = $self->get_template({ file => 'tool-step-welcome.tt' });

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

    my $id = $cgi->param('uploadedfileid');
    my $fh = Koha::UploadedFiles->find($id)->file_handle;

    my $all_updates = _read_csv($fh);

    my $good_rows;
    my $bad_rows;

    foreach my $biblionumber ( keys %{ $all_updates } ) {

        my $biblio = Koha::Biblios->find($biblionumber);
        if ( defined $biblio ) {
            # biblio exists
            $good_rows->{ $biblionumber }->{ updates } = $all_updates->{$biblionumber};
            $good_rows->{ $biblionumber }->{ title }   = $biblio->title // '';
        } else {
            # biblio doesn't exist
            $bad_rows->{ $biblionumber }->{ updates }  = $all_updates->{$biblionumber};
        }
    }

    close $fh;

    $template = $self->get_template({ file => 'tool-step-results.tt' });
    $template->param(
        good_rows      => $good_rows,
        bad_rows       => $bad_rows,
        uploadedfileid => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub tool_step_apply {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template;

    my $append        = $cgi->param('append') // 0;
    my $id            = $cgi->param('uploadedfileid');
    my $uploaded_file = Koha::UploadedFiles->find( $id );
    my $fh            = $uploaded_file->file_handle;

    my $all_updates = _read_csv($fh);

    my $good_rows;
    my $bad_rows;

    foreach my $biblionumber ( keys %{ $all_updates } ) {

        my $biblio = Koha::Biblios->find($biblionumber);
        if ( defined $biblio ) {
            # biblio exists
            # Get the MARC record as Koha does
            my $record          = GetMarcBiblio({ biblionumber => $biblio->biblionumber });
            my $fw              = GetFrameworkCode( $biblio->biblionumber );
            my $modified_record = $record->clone();
            _add_urls( $modified_record, $all_updates->{ $biblionumber }, $append );
            ModBiblio( $modified_record, $biblio->biblionumber, $fw );
        } else {
            # biblio doesn't exist
            $bad_rows->{ $biblionumber }->{ updates }  = $all_updates->{$biblionumber};
        }
    }

    close $fh;
    $uploaded_file->delete;

    $template = $self->get_template({ file => 'tool-step-final.tt' });
    $template->param(
        bad_rows       => $bad_rows,
        uploadedfileid => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub tool_step_cancel {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $id = $cgi->param('uploadedfileid');

    Koha::UploadedFiles->find( $id )->delete
        if defined $id;

    my $template = $self->get_template({ file => 'tool-step-welcome.tt' });

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();
}

sub show_diff {

    my $self = shift;
    my $cgi  = $self->{cgi};

    my $biblionumber = $cgi->param('biblionumber');
    my $id           = $cgi->param('uploadedfileid');
    my $append       = $cgi->param('append') // 0;

    my $fh = Koha::UploadedFiles->find( $id )->file_handle;

    my $all_updates = _read_csv($fh);
    my $updates = $all_updates->{$biblionumber};

    my $record          = GetMarcBiblio({ biblionumber => $biblionumber });
    my $modified_record = $record->clone();
    _add_urls( $modified_record, $updates, $append );

    my $template = $self->get_template({ file => 'marc-diff.tt' });
    $template->param(
        BIBLIONUMBER    => $biblionumber,
        MARC_FORMATTED1 => $record->as_formatted,
        MARC_FORMATTED2 => $modified_record->as_formatted,
        uploadedfileid  => $id
    );

    print $cgi->header( -charset => 'utf-8' );
    print $template->output();

}

sub _read_csv {
    my ( $fh ) = shift;

    my $updates;

    my $csv = Text::CSV->new( { binary => 1 } )    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();
    $csv->column_names(qw( biblionumber url text ));
    $csv->getline_hr($fh);                         #drop the first line

    while ( my $row = $csv->getline_hr($fh) ) {
        push @{ $updates->{ $row->{biblionumber} } },
                { url => $row->{url}, text => $row->{text} };
    }

    $csv->eof or $csv->error_diag();
    close $fh;

    return $updates;
}

sub _add_urls {
    my ( $record, $updates, $append, $criteria ) = @_;
    # Default to IA links
    $criteria //= qr/^(http\:|https\:)\/\/archive\.org/;

    # Check if we need to delete the matching fields first, do so
    if ( !$append ) {
        my @url_fields = $record->field('856');
        foreach my $url_field ( @url_fields ) {
            my $subfield_u = $url_field->subfield('u');
            if ( $subfield_u =~ m/$criteria/ ) {
                $record->delete_fields($url_field);
            }
        }
    }
    # Actually add the URLs
    foreach my $update ( @{ $updates } ) {
        _add_url( $record, $update->{url}, $update->{text} );
    }
}

sub _add_url {
    my ( $record, $url, $text ) = @_;
    my $ind1 = ( $url =~ m/^http/ ) ? 4 : '';
    my $field = MARC::Field->new( '856', $ind1, '', u => $url, y => $text );
    $record->insert_fields_ordered($field);
}

1;
