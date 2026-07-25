WHERE pmt.CreatedDate >= @fromDate 
  AND pmt.CreatedDate < DATEADD(DAY, 1, @toDate)
