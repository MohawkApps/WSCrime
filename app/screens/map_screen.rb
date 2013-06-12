class MapScreen < PM::MapScreen

  include BW::Reactor

  start_position latitude: 36.10, longitude: -80.26, radius: 4

  def on_load

    #Init instance values
    @theDate = NSDate.date

    #Set the application title
    self.setTitle("Crime Map", subtitle:"Winston-Salem, NC")

    #Setup the toolbar and navigationbar
    self.navigationController.setToolbarHidden(false)
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.toolbar.barStyle = UIBarStyleBlack;

    #Create buttons
    set_nav_bar_button :right, {
      image: UIImage.imageNamed("location"),
      style: UIBarButtonItemStyleBordered,
      action: :rezoom
    }

    set_nav_bar_button :left, {
      image: UIImage.imageNamed("list"),
      style: UIBarButtonItemStyleBordered,
      action: :show_detail
    }

    aboutButton = UIBarButtonItem.alloc.initWithTitle(
      "About",
      style: UIBarButtonItemStyleBordered,
      target: self,
      action: "show_about")

    arButton = UIBarButtonItem.alloc.initWithImage(
      UIImage.imageNamed("radar"),
      style: UIBarButtonItemStyleBordered,
      target: self,
      action: "loadARWindow:")

    flexibleSpace = UIBarButtonItem.alloc.initWithBarButtonSystemItem(
      UIBarButtonSystemItemFlexibleSpace,
      target:nil,
      action:nil)

    @activityView = UIActivityIndicatorView.alloc.initWithActivityIndicatorStyle(UIActivityIndicatorViewStyleWhite)
    @activityView.hidesWhenStopped = true
    @activityView.startAnimating()
    @activityViewButton = UIBarButtonItem.alloc.initWithCustomView(@activityView)

    @dateButton = UIBarButtonItem.alloc.initWithTitle(
      "Loading data...",
       style: UIBarButtonItemStyleBordered,
       target: self,
       action: "changeDate:")

    if ARKit.deviceSupportsAR || Device.simulator?
      self.toolbarItems = [aboutButton, arButton, flexibleSpace, @activityViewButton, @dateButton]
    else
      self.toolbarItems = [aboutButton, flexibleSpace, @activityViewButton, @dateButton]
    end

    #Send a request off to the server to get the data.
    load_data
  end

  def on_appear
    # Show the about window if this is their first time loading the app.
    show_about unless App::Persistence['seenAbout'] == "yes"
    self.navigationController.setToolbarHidden(false, animated:true)
  end

  #This method loads the data from my server and sets the data into the map annotations
  def load_data
    @dateButton.title = "Loading data..."
    @activityView.startAnimating

    #Find the date to use
    dateFormat = NSDateFormatter.new
    dateFormat.setDateFormat("yyyy-MM-dd")
    dateString = dateFormat.stringFromDate(@theDate)

    CrimeAPI.dataForDate(dateString) do |json, error|

      if error.nil?

          clear_annotations
          if json.count > 0

            json.each do |cd|
              add_annotation({
                latitude: cd['latitude'],
                longitude: cd['longitude'],
                title: cd['location'],
                subtitle: "#{cd['date_time']} : #{cd['offense_charge']}",
                pin_color: cd['type'] == "Arrest" ? MKPinAnnotationColorRed : MKPinAnnotationColorPurple,
                sort_by: cd['timestamp'],
                date: cd['date_day'],
                type: cd['type']
              })
            end
            dateAndZoom

          else

            App.alert("No Results Found for that day.")
            @activityView.stopAnimating
            @dateButton.title = "No Results"

          end
      else

        App.alert("Whoops! There was an error downloading data from the server. Please check your internet connection or try again later.")
        @dateButton.title = "Server Error"
        @activityView.stopAnimating

      end

    end # CrimeAPI block
  end

  def dateAndZoom
    @dateButton.title = @theDate.to_s
    @activityView.stopAnimating

    # Sometimes the API returns back data for a date that isn't the date we selected.
    # Get the first crime so we can make sure @theDate is set correctly for our data
    dateParts = annotations.first.date.split("-")

    @theDate = Time.mktime(dateParts[0], dateParts[1], dateParts[2])
    @dateButton.title = @theDate.strftime("%b %e, %Y")

    #Only change the map zoom if this is the first data load.
    @didInitialPinZoom ||= begin
      zoom_to_fit_annotations
    end
  end

  #Present the about window in a modal view.
  def show_about
    open_modal AboutScreen.new(nav_bar: true)
  end

  def show_detail
    if annotations.length == 0
        App.alert("There are no incidents to view.")
        return
    end

    open_modal DetailScreen.new(:nav_bar => true, :data => annotations.mutableCopy, :date => @dateButton.title, :parentVC => self ),
      transition_style: UIModalTransitionStyleFlipHorizontal,
      presentation_style: UIModalPresentationFormSheet
  end

  def closeDetailAndZoomToEvent(marker)
    self.navigationController.dismissModalViewControllerAnimated(true)

    # Close all the annotations just in case
    unless self.view.selectedAnnotations.nil?
      self.view.selectedAnnotations.each do |annotation|
        self.view.deselectAnnotation(annotation, animated:false)
      end
    end

    EM.add_timer 0.75 do
      zoomToAndSelectMarker marker
    end

  end

  def zoomToAndSelectMarker(marker)
    region = MKCoordinateRegionMake( marker.coordinate, MKCoordinateSpanMake( 0.05, 0.05 ) )
    self.view.setRegion(region, animated:true)
    self.view.selectAnnotation(marker, animated:true)
  end

  #Present the calendar view to change the date.
  def changeDate(sender)

    @calendarComponent ||= TSQCalendarView.alloc.initWithFrame(CGRectZero)
    @calendarComponent.rowCellClass = TSQTACalendarRowCell
    @calendarComponent.firstDate = Time.local(2007,11, 10)
    @calendarComponent.lastDate = Time.now
    @calendarComponent.selectedDate = @theDate
    @calendarComponent.delegate = self
    @calendarComponent.backgroundColor = UIColor.whiteColor

    calendarVC = CalendarScreen.new
    calendarVC.view = @calendarComponent

    dateNavController = PortraitNavigationController.alloc.initWithRootViewController calendarVC
    dateNavController.setModalPresentationStyle(UIModalPresentationFormSheet)

    self.navigationController.presentModalViewController(dateNavController, animated:true)
  end

  def calendarView(calendarView, didSelectDate:date)
    if @theDate.isEqualToDate(date) == false

      if date.laterDate(Time.now) == date
        App.alert("Please select a date\nin the past.")
        return
      end

      @theDate = date
      load_data
      self.navigationController.dismissModalViewControllerAnimated(true)
    end
  end

  # Augmented Reality

  def loadARWindow(sender)

    if annotations.length == 0
        App.alert("There are no incidents to view.")
        return
    end

    if ARKit.deviceSupportsAR || Device.simulator?

        arVC = ARViewController.alloc.initWithDelegate( self )
        arVC.setRadarRange(4000.0)
        arVC.setOnlyShowItemsWithinRadarRange(true)
        arVC.showsCloseButton = false
        arVC.setHidesBottomBarWhenPushed(true)
        arVC.setRotateViewsBasedOnPerspective(false)

        self.navigationController.pushViewController(arVC, animated:true)

    end
  end

  def geoLocations

    locationArray = []

     annotations.each do |thisAnnotation|
       locationArray << ARGeoCoordinate.coordinateWithLocation(thisAnnotation.cllocation, locationTitle:thisAnnotation.offense)
     end

    locationArray
  end

  def locationClicked(coordinate)
#    puts coordinate
  end

end #MapController
