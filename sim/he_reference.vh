// Integer reference shared by the full-chain and injected-histogram tests.
// Caller provides histogram[256], mapping[256], and FRAME_PIXELS.
task automatic build_reference;
    integer k,lo,hi,limit,overflow,total,count;
    begin
        lo=255;hi=0;overflow=0;total=0;
        limit=(FRAME_PIXELS+127)/128;
        for(k=0;k<256;k=k+1)begin
            if(histogram[k]!=0)begin
                if(k<lo)lo=k;
                hi=k;
            end
            if(histogram[k]>limit)overflow=overflow+histogram[k]-limit;
        end
        for(k=0;k<256;k=k+1)begin
            count=histogram[k]>limit?limit:histogram[k];
            total=total+count+overflow/256+(k<overflow%256?1:0);
            mapping[k]=hi-lo<=8?k:(3*k+(255*total)/FRAME_PIXELS)/4;
        end
        if(total!=FRAME_PIXELS)$fatal(1,"reference histogram lost counts");
    end
endtask
