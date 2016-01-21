#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Find;
use File::Basename;
use Encode;
use Archive::Zip;
use CGI;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
$imagelol->enable_silent_logging(); # silent
my %config = $imagelol->get_config();

# Log
sub log_it{
	$imagelol->log_it("album-download", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("album-download", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("album-download", "@_");
	return 0;
}

# ZIP an entire album on-the-fly
sub zip_album{
	my $album = shift;
	(my $prettyname = lc($album->{name})) =~ s/[^a-zA-Z]+//g;	# strip all but a-z
	$prettyname = substr($prettyname, 0, 15); 			# limit filename to 15 chars
	(my $year = lc($album->{name})) =~ s/^.+([0-9]{4}).*$/$1/; 	# find year, if possible
	if($year){
		$year = "-$year";
	} else {
		$year = "";
	}
	my $filename = "album-" . $prettyname . $year . ".zip";
	
	my $zip = Archive::Zip->new();

	# get all images in album
	my $images = $imagelol->get_album_images($album->{albumid});
	
	if($images){
		foreach my $image (keys %$images){
			# image name
			my ($filename, $foo_path, $ext) = fileparse($images->{$image}{path_preview}, '\..*');
		
			# handle duplicate images by using suffix
			if($images->{$image}{suffix} > 1){
				# duplicate image, handle it!
				$filename = $filename . "_" . $images->{$image}{suffix} . $ext;
			} else {
				# not a duplicate image, or duplicate image #1
				# in either of these cases, we keep the original image name
				$filename = $filename . $ext;
			}
		
			$zip->addFile($images->{$image}{path_preview}, $filename);
		}

		# set binmode
		binmode STDOUT;
	
		# header
		print "Content-type: application/octet-stream\n";
		print "Content-Disposition: attachment; filename=\"$filename\"\n\n"; # need extra line after header
	
		# flush stdout after the header
		$|=1;
	
		# send to browser
		$zip->writeToFileHandle(\*STDOUT, 0);
	} else {
		# no images -- should not happen
		# print error
		not_found();
	}
}

# print 404
sub not_found{
	my $header = CGI::header(
		-type => 'text/html',
		-status => '404 Not Found',
		-charset => 'utf-8',
	);
	
	print $header;
	print "Album not found.\n";
}

# Let's start...
$imagelol->connect();

# fetch album name
my $cgi = CGI->new();
my $album_uuid = $cgi->param('uuid');

# Check if album exists
if ($album_uuid){
	# find by uuid
	my $album = $imagelol->get_album_by_uuid($album_uuid);
	if($album){
		if($album->{enabled}){
			# valid album + enabled
			zip_album($album);
		} else {
			# album not enabled
			# return 404 not found
			not_found();
		}
	} else {
		# no album with that id
		# return 404 not found
		not_found();
	}
} else {
	# neither provided
	not_found();
}

# done
$imagelol->disconnect();
