package Thruk::Utils::Reports;

=head1 NAME

Thruk::Utils::Reports - Utilities Collection for Reporting

=head1 DESCRIPTION

Utilities Collection for Reporting

=cut

use warnings;
use strict;
use Carp;
use Class::Inspector;
use File::Slurp;
use Data::Dumper;
use Thruk::Utils::CLI;
use Thruk::Utils::PDF;
use MIME::Lite;

##########################################################

=head1 METHODS

=head2 get_report_list

  get_report_list($c)

return list of all reports for this user

=cut
sub get_report_list {
    my($c) = @_;

    my $reports = [];
    for my $rfile (glob($c->config->{'var_path'}.'/reports/*.txt')) {
        if($rfile =~ m/\/(\d+)\.txt/mx) {
            my $r = _read_report_file($c, $1);
            push @{$reports}, $r if defined $r;
        }
    }

    # sort by name
    @{$reports} = sort { $a->{'name'} cmp $b->{'name'} } @{$reports};

    return $reports;
}

##########################################################

=head2 report_show

  report_show($c, $nr)

generate and show the report

=cut
sub report_show {
    my($c, $nr, $refresh) = @_;

    my $report = _read_report_file($c, $nr);
    if(!defined $report) {
        Thruk::Utils::set_message( $c, 'fail_message', 'no such report' );
        return $c->response->redirect('reports.cgi');
    }

    my $pdf_file = $c->config->{'tmp_path'}.'/reports/'.$nr.'.pdf';
    if($refresh or ! -f $pdf_file) {
        generate_report($c, $nr, $report);
    }
    if(defined $pdf_file and -f $pdf_file) {
        $c->stash->{'pdf_template'} = 'passthrough_pdf.tt';
        $c->stash->{'pdf_file'}     = $pdf_file;
        $c->stash->{'pdf_filename'} = $report->{'name'}.'.pdf'; # downloaded filename
        $c->forward('View::PDF::Reuse');
    }
    return 1;
}

##########################################################

=head2 report_send

  report_send($c, $nr)

generate and send the report

=cut
sub report_send {
    my($c, $nr) = @_;

    my $report   = _read_report_file($c, $nr);
    if(!defined $report) {
        Thruk::Utils::set_message( $c, 'fail_message', 'no such report' );
        return $c->response->redirect('reports.cgi');
    }

    my $pdf_file = generate_report($c, $nr, $report);
    if(defined $pdf_file) {

        $c->stash->{'block'} = 'mail';
        my $mailtext;
        eval {
            $mailtext = $c->view("View::TT")->render($c, $c->stash->{'pdf_template'});
        };
        if($@) {
            Thruk::Utils::CLI::_error($@);
            return $c->detach('/error/index/13');
        }

        # extract mail header
        my $mailbody    = "";
        my $bodystarted = 0;
        my $mailheader  = {};
        for my $line (split/\n/mx, $mailtext) {
            if($line !~ m/^$/mx and $line !~ m/^[A-Z]+:/mx) {
                $bodystarted = 1;
            }
            if($bodystarted) {
                $mailbody .= $line."\n"
            } elsif($line =~ m/^([A-Z]+):\s*(.*)$/mx) {
                $mailheader->{lc($1)} = $2;
            }
            if($line =~ m/^$/mx) {
                $bodystarted = 1;
            }
        }
        my $msg = MIME::Lite->new();
        $msg->build(
                 From    => $report->{'from'}    || $mailheader->{'from'},
                 To      => $report->{'to'}      || $mailheader->{'to'},
                 Cc      => $report->{'cc'}      || $mailheader->{'cc'},
                 Bcc     => $report->{'bcc'}     || $mailheader->{'bcc'},
                 Subject => $report->{'subject'} || $mailheader->{'subject'} || 'Thruk Report',
                 Type    => 'multipart/mixed',
        );
        for my $key (keys %{$mailheader}) {
            my $value = $mailheader->{$key};
            $key = lc($key);
            next if $key eq 'from';
            next if $key eq 'to';
            next if $key eq 'cc';
            next if $key eq 'bcc';
            next if $key eq 'subject';
            $msg->add($key => $mailheader->{$key});
        }
        $msg->attach(Type     => 'TEXT',
                     Data     => $mailbody,
        );
        $msg->attach(Type    => 'application/pdf',
                 Path        => $pdf_file,
                 Filename    => 'report.pdf',
                 Disposition => 'attachment',
        );
        return 1 if $msg->send;
    }
    Thruk::Utils::set_message( $c, 'fail_message', 'failed to send report' );
    return 0;
}

##########################################################

=head2 report_save

  report_save($c, $nr, $data)

save a report

=cut
sub report_save {
    my($c, $nr, $data) = @_;
    mkdir($c->config->{'var_path'}.'/reports/');
    my $file = $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
    my $old_report;
    if($nr ne 'new' and -f $file) {
        $old_report = _read_report_file($c, $nr);
        return unless defined $old_report;
    }
    my $report       = _get_new_report($c, $data);
    $report->{'var'} = $old_report->{'var'} if defined $old_report->{'var'};
    delete $report->{'readonly'};
    delete $report->{'nr'};
    return _report_save($c, $nr, $report);
}

##########################################################

=head2 report_remove

  report_remove($c, $nr)

remove report

=cut
sub report_remove {
    my($c, $nr) = @_;

    my $report = _read_report_file($c, $nr);
    return unless defined $report;
    return unless defined $report->{'readonly'};
    return unless $report->{'readonly'} == 0;

    my @files;
    push @files, $c->config->{'var_path'}.'/reports/'.$nr.'.txt' if -e $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
    push @files, $c->config->{'tmp_path'}.'/reports/'.$nr.'.pdf' if -e $c->config->{'tmp_path'}.'/reports/'.$nr.'.pdf';
    return 1 if unlink @files;
    return;
}

##########################################################

=head2 generate_report

  generate_report($c, $nr, $options)

generate a new report

=cut
sub generate_report {
    my($c, $nr, $options) = @_;
    $Thruk::Utils::PDF::c = $c;
    $Thruk::Utils::CLI::c = $c;

    $c->stash->{'tmp_files_to_delete'} = [];

    $c->stats->profile(begin => "Utils::Reports::generate_report()");
    $options = _read_report_file($c, $nr) unless defined $options;
    return unless defined $options;

    my $pdf_file = $c->config->{'tmp_path'}.'/reports/'.$nr.'.pdf';

    # report is already beeing generated
    if($options->{'var'}->{'is_running'}) {
        while($options->{'var'}->{'is_running'}) {
            if(kill(0, $options->{'var'}->{'is_running'}) != 1) {
                unlink($pdf_file);
                last;
            }
            sleep 1;
        }
        # just wait till its finished and return
        if(-e $pdf_file) {
            return $pdf_file;
        }
    }

    # update report runtime data
    $options->{'var'}->{'is_running'} = $$;
    $options->{'var'}->{'start_time'} = time();
    _report_save($c, $nr, $options);

    unless ($c->user_exists) {
        $ENV{'REMOTE_USER'} = $options->{'user'};
        $c->authenticate( {} );
    }

    if(defined $options->{'backends'}) {
        $options->{'backends'} = ref $options->{'backends'} eq 'ARRAY' ? $options->{'backends'} : [ $options->{'backends'} ];
        if(scalar @{$options->{'backends'}} > 0) {
            $c->{'db'}->disable_backends();
            $c->{'db'}->enable_backends($options->{'backends'});
        }
    }

    # set some defaults
    Thruk::Utils::PDF::set_unavailable_states([qw/DOWN UNREACHABLE CRITICAL UNKNOWN/]);
    $c->{'request'}->{'parameters'}->{'show_log_entries'}           = 1;
    $c->{'request'}->{'parameters'}->{'assumeinitialstates'}        = 'yes';
    $c->{'request'}->{'parameters'}->{'initialassumedhoststate'}    = 3; # UP
    $c->{'request'}->{'parameters'}->{'initialassumedservicestate'} = 6; # OK


    $c->stash->{'param'} = $options->{'params'};
    for my $p (keys %{$options->{'params'}}) {
        $c->{'request'}->{'parameters'}->{$p} = $options->{'params'}->{$p};
    }

    if(!defined $options->{'template'} or !Thruk::Utils::PDF::path_to_template('pdf/'.$options->{'template'})) {
        confess('template pdf/'.$options->{'template'}.' does not exist');
    }

    # set some render helper
    for my $s (@{Class::Inspector->functions('Thruk::Utils::PDF')}) {
        $c->stash->{$s} = \&{'Thruk::Utils::PDF::'.$s};
    }

    # prepare pdf
    $c->stash->{'pdf_template'} = 'pdf/'.$options->{'template'};
    $c->stash->{'block'} = 'prepare';
    eval {
        $c->view("PDF::Reuse")->render_pdf($c);
    };
    if($@) {
        Thruk::Utils::CLI::_error($@);
        return $c->detach('/error/index/13');
    }

    # render pdf
    $c->stash->{'block'} = 'render';
    my $pdf_data;
    eval {
        $pdf_data = $c->view("PDF::Reuse")->render_pdf($c);
    };
    if($@) {
        Thruk::Utils::CLI::_error($@);
        return $c->detach('/error/index/13');
    }

    # write out pdf
    mkdir($c->config->{'tmp_path'}.'/reports');
    open(my $fh, '>', $pdf_file);
    binmode $fh;
    print $fh $pdf_data;
    close($fh);

    # clean up tmp files
    for my $file (@{$c->stash->{'tmp_files_to_delete'}}) {
        unlink($file);
    }

    # update report runtime data
    $options = _read_report_file($c, $nr);
    $options->{'var'}->{'end_time'}   = time();
    $options->{'var'}->{'is_running'} = 0;
    _report_save($c, $nr, $options);

    $c->stats->profile(end => "Utils::Reports::generate_report()");
    return $pdf_file;
}

##########################################################

=head2 get_report_data_from_param

  get_report_data_from_param($params)

return report data for given params

=cut
sub get_report_data_from_param {
    my $params = shift;
    my $p = {};
    for my $key (keys %{$params}) {
        next unless $key =~ m/^params\.([\w\.]+)$/mx;
        if(ref $params->{$key} eq 'ARRAY') {
            # remove empty elements
            @{$params->{$key}} = grep(!/^$/mx, @{$params->{$key}});
        }
        $p->{$1} = $params->{$key};
    }

    my $data = {
        'name'      => $params->{'name'}        || 'New Report',
        'desc'      => $params->{'desc'}        || '',
        'template'  => $params->{'template'}    || 'sla.tt',
        'is_public' => $params->{'is_public'}   || 0,
        'to'        => $params->{'to'}          || '',
        'cc'        => $params->{'cc'}          || '',
        'backends'  => $params->{'backends'}    || [],
        'params'    => $p,
    };

    return($data);
}

##########################################################
sub _get_new_report {
    my($c, $data) = @_;
    $data = {} unless defined $data;
    my $r = {
        'name'      => 'New Report',
        'desc'      => 'Description',
        'nr'        => 'new',
        'template'  => '',
        'params'    => {},
        'var'       => {},
        'to'        => '',
        'cc'        => '',
        'is_public' => 0,
        'user'      => $c->stash->{'remote_user'},
        'backends'  => [],
    };
    for my $key (keys %{$data}) {
        $r->{$key} = $data->{$key};
    }
    return $r;
}

##########################################################
sub _report_save {
    my($c, $nr, $report) = @_;
    mkdir($c->config->{'var_path'}.'/reports/');
    my $file = $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
    if($nr eq 'new') {
        # find next free number
        $nr = 1;
        $file = $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
        while(-e $file) {
            $nr++;
            $file = $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
        }
    }
    my $data = Dumper($report);
    $data    =~ s/^\$VAR1\ =\ //mx;
    $data    =~ s/^\ \ \ \ \ \ \ \ //gmx;
    open(my $fh, '>'.$file) or confess('cannot write to '.$file.": ".$!);
    print $fh $data;
    close($fh);
    return $nr;
}

##########################################################
sub _read_report_file {
    my($c, $nr, $rdata) = @_;
    unless($nr =~ m/^\d+$/mx) {
        Thruk::Utils::CLI::_error("not a valid report number");
        return $c->detach('/error/index/13');
    }
    my $file = $c->config->{'var_path'}.'/reports/'.$nr.'.txt';
    unless(-f $file) {
        Thruk::Utils::CLI::_error("report does not exist: $!");
        return $c->detach('/error/index/13');
    }
    my $data = read_file($file);
    my $report;
    ## no critic
    eval('$report = '.$data.';');
    ## use critic

    $report->{'readonly'}   = 1;
    my $authorized = _is_authorized_for_report($c, $report);
    return unless $authorized;
    $report->{'readonly'}   = 0 if $authorized == 1;

    # add some runtime information
    my $rfile = $c->config->{'tmp_path'}.'/reports/'.$nr.'.pdf';
    $report->{'var'}->{'pdf_exists'} = 0;
    $report->{'var'}->{'pdf_exists'} = 1 if -f $rfile;
    $report->{'var'}->{'is_running'} = 0 unless defined $report->{'var'}->{'is_running'};
    $report->{'var'}->{'start_time'} = 0 unless defined $report->{'var'}->{'start_time'};
    $report->{'var'}->{'end_time'}   = 0 unless defined $report->{'var'}->{'end_time'};
    $report->{'desc'}       = '' unless defined $report->{'desc'};
    $report->{'to'}         = '' unless defined $report->{'to'};
    $report->{'cc'}         = '' unless defined $report->{'cc'};
    $report->{'nr'}         = $nr;
    $report->{'is_public'}  = 0 unless defined $report->{'is_public'};

    # preset values from data
    if(defined $rdata) {
        for my $key (keys %{$rdata}) {
            $report->{$key} = $rdata->{$key};
        }
    }

    return $report;
}

##########################################################
sub _is_authorized_for_report {
    my($c, $report) = @_;
    return 1 if defined $ENV{'THRUK_SRC'} and $ENV{'THRUK_SRC'} eq 'CLI';
    if(defined $report->{'is_public'} and $report->{'is_public'} == 1) {
        return 2;
    }
    if(defined $report->{'user'} and defined $c->stash->{'remote_user'} and $report->{'user'} eq $c->stash->{'remote_user'}) {
        return 1;
    }
    Thruk::Utils::CLI::_debug("user: ".$c->stash->{'remote_user'}." is not authorized for report: ".$report->{'nr'});
    return;
}

##########################################################

1;