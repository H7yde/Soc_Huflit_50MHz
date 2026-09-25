`timescale 1ns/1ps

// Synthesizable sequential CNN core. One MAC is used per clock.
// Interface and memory format are kept compatible with CNN.v and the
// existing conv*_weight.mem/fc_weight.mem files.
module cnn_docx_reference(
    input wire clk, input wire rst, input wire [23:0] pixel_data,
    input wire pixel_valid, output reg pixel_ready,
    output reg result_valid, output reg classification
);
    localparam CAP=0,C1=1,P1=2,C2=3,P2=4,C3=5,P3=6,FC=7,DONE=8;
    reg [3:0] st;
    reg [10:0] pix;
    reg [11:0] n;
    reg [5:0] k;
    reg [2:0] pk;
    reg [4:0] fi;
    reg signed [31:0] acc;
    reg signed [7:0] pmax;

    reg [23:0] image [0:1023];
    reg signed [7:0] w1 [0:107], w2 [0:143], w3 [0:143], wf [0:15];
    reg signed [7:0] c1 [0:3599], p1 [0:899];
    reg signed [7:0] c2 [0:675],  p2 [0:143];
    reg signed [7:0] c3 [0:63],   p3 [0:15];

    integer rem, oc, ic, x, y, kx, ky, si, wi;
    integer prem, poc, px, py;
    reg signed [7:0] sample, pool_sample, weight_value;
    reg signed [31:0] product, total;

    initial begin
        $readmemh("D:/LAB/custom_SOC/CNN_RTL/conv1_rgb_weight.mem",w1);
        $readmemh("D:/LAB/custom_SOC/CNN_RTL/conv2_weight.mem",w2);
        $readmemh("D:/LAB/custom_SOC/CNN_RTL/conv3_weight.mem",w3);
        $readmemh("D:/LAB/custom_SOC/CNN_RTL/fc_weight.mem",wf);
    end

    function [7:0] qrelu;
        input signed [31:0] v;
        reg signed [31:0] q;
        begin
            q=v>>>4;
            if(q<0) qrelu=0; else if(q>127) qrelu=127; else qrelu=q[7:0];
        end
    endfunction

    // Address generation for the current MAC. Only one multiplier is
    // instantiated by this datapath instead of unrolling every convolution.
    always @* begin
        rem=0; oc=0; ic=0; x=0; y=0; kx=0; ky=0; si=0; wi=0;
        sample=0; weight_value=0; product=0;
        if(st==C1) begin
            oc=n/900; rem=n%900; y=rem/30; x=rem%30;
            ic=k/9; rem=k%9; ky=rem/3; kx=rem%3;
            si=(y+ky)*32+x+kx;
            if(ic==0) sample=(image[si][23:16]*16)/255;
            else if(ic==1) sample=(image[si][15:8]*16)/255;
            else sample=(image[si][7:0]*16)/255;
            wi=oc*27+k; weight_value=w1[wi];
        end else if(st==C2) begin
            oc=n/169; rem=n%169; y=rem/13; x=rem%13;
            ic=k/9; rem=k%9; ky=rem/3; kx=rem%3;
            si=ic*225+(y+ky)*15+x+kx; sample=p1[si];
            wi=oc*36+k; weight_value=w2[wi];
        end else if(st==C3) begin
            oc=n/16; rem=n%16; y=rem/4; x=rem%4;
            ic=k/9; rem=k%9; ky=rem/3; kx=rem%3;
            si=ic*36+(y+ky)*6+x+kx; sample=p2[si];
            wi=oc*36+k; weight_value=w3[wi];
        end else if(st==FC) begin
            // FC weights use pixel-major order:
            // (pixel0 ch0..ch3), (pixel1 ch0..ch3), ...
            // p3 is stored channel-major by the pooling stage, therefore
            // transpose the 4x4 indexing before multiplying.
            sample=p3[(fi%4)*4+(fi/4)];
            weight_value=wf[fi];
        end
        product=$signed(sample)*$signed(weight_value);
    end

    // Pooling sample address. Pooling also uses one comparison per clock.
    always @* begin
        prem=0; poc=0; px=0; py=0; pool_sample=0;
        if(st==P1) begin
            poc=n/225; prem=n%225; py=prem/15; px=prem%15;
            pool_sample=c1[poc*900+(2*py+pk/2)*30+2*px+(pk%2)];
        end else if(st==P2) begin
            poc=n/36; prem=n%36; py=prem/6; px=prem%6;
            pool_sample=c2[poc*169+(2*py+pk/2)*13+2*px+(pk%2)];
        end else if(st==P3) begin
            poc=n/4; prem=n%4; py=prem/2; px=prem%2;
            pool_sample=c3[poc*16+(2*py+pk/2)*4+2*px+(pk%2)];
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            st<=CAP; pix<=0; n<=0; k<=0; pk<=0; fi<=0; acc<=0;
            pmax<=0; pixel_ready<=1; result_valid<=0; classification<=0;
        end else begin
            result_valid<=0;
            case(st)
                CAP: begin
                    pixel_ready<=1;
                    if(pixel_valid && pixel_ready) begin
                        image[pix]<=pixel_data;
                        if(pix==1023) begin pix<=0; n<=0; k<=0; acc<=0;
                            pixel_ready<=0; st<=C1;
                        end else pix<=pix+1;
                    end
                end
                C1,C2,C3: begin
                    total=acc+product;
                    if(k==((st==C1)?26:35)) begin
                        if(st==C1) c1[n]<=qrelu(total);
                        else if(st==C2) c2[n]<=qrelu(total);
                        else c3[n]<=qrelu(total);
                        acc<=0; k<=0;
                        if(st==C1) begin
                            if(n==3599) begin n<=0; pk<=0; st<=P1; end
                            else n<=n+1;
                        end else if(st==C2) begin
                            if(n==675) begin n<=0; pk<=0; st<=P2; end
                            else n<=n+1;
                        end else begin
                            if(n==63) begin n<=0; pk<=0; st<=P3; end
                            else n<=n+1;
                        end
                    end else begin acc<=total; k<=k+1; end
                end
                P1,P2,P3: begin
                    if(pk==0) pmax<=pool_sample;
                    else if(pool_sample>pmax) pmax<=pool_sample;
                    if(pk==3) begin
                        if(st==P1) p1[n]<=pool_sample>pmax?pool_sample:pmax;
                        else if(st==P2) p2[n]<=pool_sample>pmax?pool_sample:pmax;
                        else p3[n]<=pool_sample>pmax?pool_sample:pmax;
                        pk<=0;
                        if(st==P1) begin
                            if(n==899) begin n<=0; st<=C2; end else n<=n+1;
                        end else if(st==P2) begin
                            if(n==143) begin n<=0; st<=C3; end else n<=n+1;
                        end else begin
                            if(n==15) begin fi<=0; acc<=0; st<=FC; end
                            else n<=n+1;
                        end
                    end else pk<=pk+1;
                end
                FC: begin
                    total=acc+product;
                    if(fi==15) begin classification<=total>=0; result_valid<=1;
                        pixel_ready<=0; st<=DONE;
                    end else begin acc<=total; fi<=fi+1; end
                end
                DONE: begin
                    // Return to capture mode after the result pulse so the
                    // AXI peripheral can start another frame without reset.
                    pixel_ready<=1; pix<=0; st<=CAP;
                end
                default: st<=CAP;
            endcase
        end
    end
endmodule
