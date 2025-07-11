#ifndef TESSELLATION_INCLUDED
#define TESSELLATION_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

#if defined(_TESSELLATION_SMOOTHING_VCOLORS) || defined(_TESSELLATION_FACTOR_VCOLORS)
    #define REQUIRES_VERTEX_COLORS
#endif
#if defined(_TESSELLATION_SMOOTHING_BEZIER_LINEAR_NORMALS)
#define NUM_BEZIER_CONTROL_POINTS 7
#elif defined(_TESSELLATION_SMOOTHING_BEZIER_QUAD_NORMALS)
#define NUM_BEZIER_CONTROL_POINTS 10
#else
#define NUM_BEZIER_CONTROL_POINTS 0
#endif

struct Attributes 
{
    float3 positionOS : POSITION;
    float3 normalOS : NORMAL;
    float4 tangentOS : TANGENT;
    float2 uv : TEXCOORD0;
#ifdef LIGHTMAP_ON
    float2 lightmapUV : TEXCOORD1;
#endif
#ifdef REQUIRES_VERTEX_COLORS
    float4 color : COLOR;
#endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct TessellationFactors 
{
    float edge[3] : SV_TessFactor;
    float inside : SV_InsideTessFactor;
#if NUM_BEZIER_CONTROL_POINTS > 0
    float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS] : BEZIERPOS;
#endif
};

struct TessellationControlPoint 
{
    float3 positionWS : INTERNALTESSPOS;
    float4 positionCS : SV_POSITION;
    float3 normalWS : NORMAL;
    float4 tangentWS : TANGENT;
    float2 uv : TEXCOORD0;
#ifdef LIGHTMAP_ON
    float2 lightmapUV : TEXCOORD1;
#endif
#ifdef REQUIRES_VERTEX_COLORS
    float4 color : COLOR;
#endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Interpolators 
{
    float2 uv                       : TEXCOORD0;
    float3 normalWS                 : TEXCOORD1;
    float3 positionWS               : TEXCOORD2;
    float4 tangentWS                : TEXCOORD3;
    DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 4);
    float4 fogFactorAndVertexLight  : TEXCOORD5;
    float4 positionCS               : SV_POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

TEXTURE2D(_MainTexture); SAMPLER(sampler_MainTexture);
TEXTURE2D(_NormalMap); SAMPLER(sampler_NormalMap);
TEXTURE2D(_HeightMap); SAMPLER(sampler_HeightMap);

CBUFFER_START(UnityPerMaterial)
    float4 _MainTexture_ST;
    float4 _MainTexture_TexelSize;
    float _NormalStrength;
    float _HeightMapAltitude;
    float _TessellationFactor;
    float _TessellationBias;
    float _TessellationSmoothing;
    float _FrustumCullTolerance;
    float _BackFaceCullTolerance;
CBUFFER_END

float3 GetViewDirectionFromPosition(float3 positionWS) 
{
    return normalize(GetCameraPositionWS() - positionWS);
}

float4 GetShadowCoord(float3 positionWS, float4 positionCS) // Get the shadow coordinates based on the type of shadows
{
#if SHADOWS_SCREEN
    return ComputeScreenPos(positionCS);
#else
    return TransformWorldToShadowCoord(positionWS);
#endif
}

TessellationControlPoint Vertex(Attributes input) 
{
    TessellationControlPoint output;

    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);

    VertexPositionInputs posnInputs = GetVertexPositionInputs(input.positionOS);
    VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS, input.tangentOS);

    output.positionWS = posnInputs.positionWS;
    output.positionCS = posnInputs.positionCS;
    output.normalWS = normalInputs.normalWS;
    output.tangentWS = float4(normalInputs.tangentWS, input.tangentOS.w);
    output.uv = TRANSFORM_TEX(input.uv, _MainTexture);
#ifdef LIGHTMAP_ON
    OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
#endif
#ifdef REQUIRES_VERTEX_COLORS
    output.color = input.color;
#endif

    return output;
}

bool IsOutOfBounds(float3 p, float3 lower, float3 higher) 
{
    return p.x < lower.x || p.x > higher.x || p.y < lower.y || p.y > higher.y || p.z < lower.z || p.z > higher.z;
}

bool IsPointOutOfFrustum(float4 positionCS, float tolerance) 
{
    float3 culling = positionCS.xyz;
    float w = positionCS.w;
    float3 lowerBounds = float3(-w - tolerance, -w - tolerance, -w * UNITY_RAW_FAR_CLIP_VALUE - tolerance);
    float3 higherBounds = float3(w + tolerance, w + tolerance, w + tolerance);
    return IsOutOfBounds(culling, lowerBounds, higherBounds);
}

bool ShouldBackFaceCull(float4 p0PositionCS, float4 p1PositionCS, float4 p2PositionCS, float tolerance) 
{
    float3 point0 = p0PositionCS.xyz / p0PositionCS.w;
    float3 point1 = p1PositionCS.xyz / p1PositionCS.w;
    float3 point2 = p2PositionCS.xyz / p2PositionCS.w;
#if UNITY_REVERSED_Z
    return cross(point1 - point0, point2 - point0).z < -tolerance;
#else
    return cross(point1 - point0, point2 - point0).z > tolerance;
#endif
}

bool ShouldClipPatch(float4 p0PositionCS, float4 p1PositionCS, float4 p2PositionCS, float frustumTolerance, float windingTolerance) 
{
    bool allOutside = IsPointOutOfFrustum(p0PositionCS, frustumTolerance) &&
        IsPointOutOfFrustum(p1PositionCS, frustumTolerance) &&
        IsPointOutOfFrustum(p2PositionCS, frustumTolerance);
    return allOutside || ShouldBackFaceCull(p0PositionCS, p1PositionCS, p2PositionCS, windingTolerance);
}

float EdgeTessellationFactor(float scale, float bias, float multiplier, float3 p0PositionWS, float4 p0PositionCS, float3 p1PositionWS, float4 p1PositionCS) // Figure the tessellation for edges
{
    float factor = 1;
#if defined(_TESSELLATION_FACTOR_CONSTANT)
    factor = scale;
#elif defined(_TESSELLATION_FACTOR_WORLD)
    factor = distance(p0PositionWS, p1PositionWS) / scale;
#elif defined(_TESSELLATION_FACTOR_WORLD_WITH_DEPTH)
    float length = distance(p0PositionWS, p1PositionWS);
    float distanceToCamera = distance(GetCameraPositionWS(), (p0PositionWS + p1PositionWS) * 0.5);
    factor = length / (scale * distanceToCamera * distanceToCamera);
#elif defined(_TESSELLATION_FACTOR_SCREEN)
    factor = distance(p0PositionCS.xyz / p0PositionCS.w, p1PositionCS.xyz / p1PositionCS.w) * _ScreenParams.y / scale;
#endif
    return max(1, (factor + bias) * multiplier);
}

#if NUM_BEZIER_CONTROL_POINTS > 0
float3 CalculateBezierControlPoint(float3 p0PositionWS, float3 aNormalWS, float3 p1PositionWS, float3 bNormalWS) 
{
    float w = dot(p1PositionWS - p0PositionWS, aNormalWS);
    return (p0PositionWS * 2 + p1PositionWS - w * aNormalWS) / 3.0;
}

void CalculateBezierControlPoints(inout float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS], float3 p0PositionWS, float3 p0NormalWS, float3 p1PositionWS, float3 p1NormalWS, float3 p2PositionWS, float3 p2NormalWS) 
{
    bezierPoints[0] = CalculateBezierControlPoint(p0PositionWS, p0NormalWS, p1PositionWS, p1NormalWS);
    bezierPoints[1] = CalculateBezierControlPoint(p1PositionWS, p1NormalWS, p0PositionWS, p0NormalWS);
    bezierPoints[2] = CalculateBezierControlPoint(p1PositionWS, p1NormalWS, p2PositionWS, p2NormalWS);
    bezierPoints[3] = CalculateBezierControlPoint(p2PositionWS, p2NormalWS, p1PositionWS, p1NormalWS);
    bezierPoints[4] = CalculateBezierControlPoint(p2PositionWS, p2NormalWS, p0PositionWS, p0NormalWS);
    bezierPoints[5] = CalculateBezierControlPoint(p0PositionWS, p0NormalWS, p2PositionWS, p2NormalWS);
    float3 avgBezier = 0;
    [unroll] for (int i = 0; i < 6; i++) {
        avgBezier += bezierPoints[i];
    }
    avgBezier /= 6.0;
    float3 avgControl = (p0PositionWS + p1PositionWS + p2PositionWS) / 3.0;
    bezierPoints[6] = avgBezier + (avgBezier - avgControl) / 2.0;
}

float3 CalculateBezierControlNormal(float3 p0PositionWS, float3 aNormalWS, float3 p1PositionWS, float3 bNormalWS) 
{
    float3 d = p1PositionWS - p0PositionWS;
    float v = 2 * dot(d, aNormalWS + bNormalWS) / dot(d, d);
    return normalize(aNormalWS + bNormalWS - v * d);
}

void CalculateBezierNormalPoints(inout float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS], float3 p0PositionWS, float3 p0NormalWS, float3 p1PositionWS, float3 p1NormalWS, float3 p2PositionWS, float3 p2NormalWS) 
{
    bezierPoints[7] = CalculateBezierControlNormal(p0PositionWS, p0NormalWS, p1PositionWS, p1NormalWS);
    bezierPoints[8] = CalculateBezierControlNormal(p1PositionWS, p1NormalWS, p2PositionWS, p2NormalWS);
    bezierPoints[9] = CalculateBezierControlNormal(p2PositionWS, p2NormalWS, p0PositionWS, p0NormalWS);
}
#endif

TessellationFactors PatchConstantFunction(InputPatch<TessellationControlPoint, 3> patch) // Runs once per triangle, checks what is out of view, calculate factors and smoothing
{
    UNITY_SETUP_INSTANCE_ID(patch[0]);
    TessellationFactors f = (TessellationFactors)0;
    if (ShouldClipPatch(patch[0].positionCS, patch[1].positionCS, patch[2].positionCS, _FrustumCullTolerance, _BackFaceCullTolerance)) 
    {
        f.edge[0] = f.edge[1] = f.edge[2] = f.inside = 0;
    } 
    else 
    {
        float3 multipliers;
#ifdef _TESSELLATION_FACTOR_VCOLORS
        [unroll] for (int i = 0; i < 3; i++) {
            multipliers[i] = patch[i].color.g;
        }
#else
        multipliers = 1;
#endif
        f.edge[0] = EdgeTessellationFactor(_TessellationFactor, _TessellationBias, (multipliers[1] + multipliers[2]) / 2, patch[1].positionWS, patch[1].positionCS, patch[2].positionWS, patch[2].positionCS);
        f.edge[1] = EdgeTessellationFactor(_TessellationFactor, _TessellationBias, (multipliers[2] + multipliers[0]) / 2, patch[2].positionWS, patch[2].positionCS, patch[0].positionWS, patch[0].positionCS);
        f.edge[2] = EdgeTessellationFactor(_TessellationFactor, _TessellationBias, (multipliers[0] + multipliers[1]) / 2, patch[0].positionWS, patch[0].positionCS, patch[1].positionWS, patch[1].positionCS);
        f.inside = (f.edge[0] + f.edge[1] + f.edge[2]) / 3.0;
        
#if defined(_TESSELLATION_SMOOTHING_BEZIER_LINEAR_NORMALS)
        CalculateBezierControlPoints(f.bezierPoints, patch[0].positionWS, patch[0].normalWS, patch[1].positionWS, patch[1].normalWS, patch[2].positionWS, patch[2].normalWS);
#elif defined(_TESSELLATION_SMOOTHING_BEZIER_QUAD_NORMALS)
        CalculateBezierControlPoints(f.bezierPoints, patch[0].positionWS, patch[0].normalWS, patch[1].positionWS, patch[1].normalWS, patch[2].positionWS, patch[2].normalWS);
        CalculateBezierNormalPoints(f.bezierPoints, patch[0].positionWS, patch[0].normalWS, patch[1].positionWS, patch[1].normalWS, patch[2].positionWS, patch[2].normalWS);
#endif
    }
    return f;
}

[domain("tri")]
[outputcontrolpoints(3)]
[outputtopology("triangle_cw")]
[patchconstantfunc("PatchConstantFunction")]

#if defined(_PARTITIONING_INTEGER)
[partitioning("integer")]
#elif defined(_PARTITIONING_FRAC_EVEN)
[partitioning("fractional_even")]
#elif defined(_PARTITIONING_FRAC_ODD)
[partitioning("fractional_odd")]
#elif defined(_PARTITIONING_POW2)
[partitioning("pow2")]
#else 
[partitioning("fractional_odd")]
#endif
TessellationControlPoint Hull(
InputPatch<TessellationControlPoint, 3> patch, uint id : SV_OutputControlPointID) 
{ 

    return patch[id];
}

float3 BarycentricInterpolate(float3 bary, float3 a, float3 b, float3 c) 
{
    return bary.x * a + bary.y * b + bary.z * c;
}

#define BARYCENTRIC_INTERPOLATE(fieldName) \
		patch[0].fieldName * barycentricCoordinates.x + \
		patch[1].fieldName * barycentricCoordinates.y + \
		patch[2].fieldName * barycentricCoordinates.z

float3 PhongProjectedPosition(float3 flatPositionWS, float3 cornerPositionWS, float3 normalWS) 
{
    return flatPositionWS - dot(flatPositionWS - cornerPositionWS, normalWS) * normalWS;
}

float3 CalculatePhongPosition(float3 bary, float smoothing, float3 p0PositionWS, float3 p0NormalWS, float3 p1PositionWS, float3 p1NormalWS, float3 p2PositionWS, float3 p2NormalWS) 
{
    float3 flatPositionWS = BarycentricInterpolate(bary, p0PositionWS, p1PositionWS, p2PositionWS);
    float3 smoothedPositionWS =
        bary.x * PhongProjectedPosition(flatPositionWS, p0PositionWS, p0NormalWS) +
        bary.y * PhongProjectedPosition(flatPositionWS, p1PositionWS, p1NormalWS) +
        bary.z * PhongProjectedPosition(flatPositionWS, p2PositionWS, p2NormalWS);
    return lerp(flatPositionWS, smoothedPositionWS, smoothing);
}

#if NUM_BEZIER_CONTROL_POINTS > 0

float3 CalculateBezierPosition(float3 bary, float smoothing, float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS], float3 p0PositionWS, float3 p1PositionWS, float3 p2PositionWS) 
{
    float3 flatPositionWS = BarycentricInterpolate(bary, p0PositionWS, p1PositionWS, p2PositionWS);
    float3 smoothedPositionWS =
        p0PositionWS * (bary.x * bary.x * bary.x) +
        p1PositionWS * (bary.y * bary.y * bary.y) +
        p2PositionWS * (bary.z * bary.z * bary.z) +
        bezierPoints[0] * (3 * bary.x * bary.x * bary.y) +
        bezierPoints[1] * (3 * bary.y * bary.y * bary.x) +
        bezierPoints[2] * (3 * bary.y * bary.y * bary.z) +
        bezierPoints[3] * (3 * bary.z * bary.z * bary.y) +
        bezierPoints[4] * (3 * bary.z * bary.z * bary.x) +
        bezierPoints[5] * (3 * bary.x * bary.x * bary.z) +
        bezierPoints[6] * (6 * bary.x * bary.y * bary.z);
    return lerp(flatPositionWS, smoothedPositionWS, smoothing);
}

float3 CalculateBezierNormal(float3 bary, float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS],
    float3 p0NormalWS, float3 p1NormalWS, float3 p2NormalWS) {
    return p0NormalWS * (bary.x * bary.x) +
        p1NormalWS * (bary.y * bary.y) +
        p2NormalWS * (bary.z * bary.z) +
        bezierPoints[7] * (2 * bary.x * bary.y) +
        bezierPoints[8] * (2 * bary.y * bary.z) +
        bezierPoints[9] * (2 * bary.z * bary.x);
}

float3 CalculateBezierNormalWithSmoothFactor(float3 bary, float smoothing, float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS],
    float3 p0NormalWS, float3 p1NormalWS, float3 p2NormalWS) {
    float3 flatNormalWS = BarycentricInterpolate(bary, p0NormalWS, p1NormalWS, p2NormalWS);
    float3 smoothedNormalWS = CalculateBezierNormal(bary, bezierPoints, p0NormalWS, p1NormalWS, p2NormalWS);
    return normalize(lerp(flatNormalWS, smoothedNormalWS, smoothing));
}

void CalculateBezierNormalAndTangent(float3 bary, float smoothing, float3 bezierPoints[NUM_BEZIER_CONTROL_POINTS],
    float3 p0NormalWS, float3 p0TangentWS, float3 p1NormalWS, float3 p1TangentWS, float3 p2NormalWS, float3 p2TangentWS,
    out float3 normalWS, out float3 tangentWS) {

    float3 flatNormalWS = BarycentricInterpolate(bary, p0NormalWS, p1NormalWS, p2NormalWS);
    float3 smoothedNormalWS = CalculateBezierNormal(bary, bezierPoints, p0NormalWS, p1NormalWS, p2NormalWS);
    normalWS = normalize(lerp(flatNormalWS, smoothedNormalWS, smoothing));

    float3 flatTangentWS = BarycentricInterpolate(bary, p0TangentWS, p1TangentWS, p2TangentWS);
    float3 flatBitangentWS = cross(flatNormalWS, flatTangentWS);
    tangentWS = normalize(cross(flatBitangentWS, normalWS));
}
#endif

[domain("tri")]
Interpolators Domain(TessellationFactors factors, OutputPatch<TessellationControlPoint, 3> patch, float3 barycentricCoordinates : SV_DomainLocation) 
{
    Interpolators output;
    UNITY_SETUP_INSTANCE_ID(patch[0]);
    UNITY_TRANSFER_INSTANCE_ID(patch[0], output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    float smoothing = _TessellationSmoothing;
#ifdef _TESSELLATION_SMOOTHING_VCOLORS
    smoothing *= BARYCENTRIC_INTERPOLATE(color.r); 
#endif
#if defined(_TESSELLATION_SMOOTHING_PHONG)
    float3 positionWS = CalculatePhongPosition(barycentricCoordinates, smoothing, patch[0].positionWS, patch[0].normalWS, patch[1].positionWS, patch[1].normalWS, patch[2].positionWS, patch[2].normalWS);
#elif defined(_TESSELLATION_SMOOTHING_BEZIER_LINEAR_NORMALS) || defined(_TESSELLATION_SMOOTHING_BEZIER_QUAD_NORMALS)
    float3 positionWS = CalculateBezierPosition(barycentricCoordinates, smoothing, factors.bezierPoints, patch[0].positionWS, patch[1].positionWS, patch[2].positionWS);
#else
    float3 positionWS = BARYCENTRIC_INTERPOLATE(positionWS);
#endif
#if defined(_TESSELLATION_SMOOTHING_BEZIER_QUAD_NORMALS)
    float3 normalWS, tangentWS;
    CalculateBezierNormalAndTangent(barycentricCoordinates, smoothing, factors.bezierPoints,
        patch[0].normalWS, patch[0].tangentWS.xyz, patch[1].normalWS, patch[1].tangentWS.xyz, patch[2].normalWS, patch[2].tangentWS.xyz,
        normalWS, tangentWS);
#else
    float3 normalWS = BARYCENTRIC_INTERPOLATE(normalWS);
    float3 tangentWS = BARYCENTRIC_INTERPOLATE(tangentWS.xyz);
#endif
    float2 uv = BARYCENTRIC_INTERPOLATE(uv);
    float height = SAMPLE_TEXTURE2D_LOD(_HeightMap, sampler_HeightMap, uv, 0).r * _HeightMapAltitude;
    positionWS += normalWS * height;
    output.uv = uv;
    output.positionCS = TransformWorldToHClip(positionWS);
    output.normalWS = normalWS;
    output.positionWS = positionWS;
    output.tangentWS = float4(tangentWS, patch[0].tangentWS.w);
    
#ifdef LIGHTMAP_ON
    output.lightmapUV = BARYCENTRIC_INTERPOLATE(lightmapUV);
#else
    OUTPUT_SH(output.normalWS, output.vertexSH);
#endif
    float fogFactor = ComputeFogFactor(output.positionCS.z);
    float3 vertexLight = VertexLighting(output.positionWS, output.normalWS);
    output.fogFactorAndVertexLight = float4(fogFactor, vertexLight);

    return output;
}

float SampleHeight(float2 uv) 
{
    return SAMPLE_TEXTURE2D(_HeightMap, sampler_HeightMap, uv).r;
}

float3 GenerateNormalFromHeightMap(float2 uv) 
{
    float left = SampleHeight(uv - float2(_MainTexture_TexelSize.x, 0));
    float right = SampleHeight(uv + float2(_MainTexture_TexelSize.x, 0));
    float down = SampleHeight(uv - float2(0, _MainTexture_TexelSize.y));
    float up = SampleHeight(uv + float2(0, _MainTexture_TexelSize.y));
    float3 normalTS = float3((left - right) / (_MainTexture_TexelSize.x * 2), (down - up) / (_MainTexture_TexelSize.y * 2), 1);
    normalTS.xy *= _NormalStrength;
    return normalize(normalTS);
}

float4 Fragment(Interpolators input) : SV_Target 
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    float4 mainSample = SAMPLE_TEXTURE2D(_MainTexture, sampler_MainTexture, input.uv);

    float3x3 tangentToWorld = CreateTangentToWorld(input.normalWS, input.tangentWS.xyz, input.tangentWS.w);
#if defined(_GENERATE_NORMALS_MAP)
    float3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, input.uv), _NormalStrength);
#elif defined(_GENERATE_NORMALS_HEIGHT)
    float3 normalTS = GenerateNormalFromHeightMap(input.uv);
#else
    float3 normalTS = float3(0, 0, 1);
#endif
    float3 normalWS = normalize(TransformTangentToWorld(normalTS, tangentToWorld));
    InputData lightingInput = (InputData)0;
    lightingInput.positionWS = input.positionWS;
    lightingInput.normalWS = normalWS;
    lightingInput.viewDirectionWS = GetViewDirectionFromPosition(lightingInput.positionWS);
    lightingInput.shadowCoord = GetShadowCoord(lightingInput.positionWS, input.positionCS);
    lightingInput.fogCoord = input.fogFactorAndVertexLight.x;
    lightingInput.vertexLighting = input.fogFactorAndVertexLight.yzw;
    lightingInput.bakedGI = SAMPLE_GI(input.lightmapUV, input.vertexSH, lightingInput.normalWS);
    lightingInput.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    lightingInput.shadowMask = SAMPLE_SHADOWMASK(input.lightmapUV);
    SurfaceData surface = (SurfaceData)0;
    surface.albedo = mainSample.rgb;
    surface.alpha = mainSample.a;
    surface.metallic = 0;
    surface.smoothness = 0.5;
    surface.normalTS = normalTS;
    surface.occlusion = 1;

    return UniversalFragmentPBR(lightingInput, surface);
}

#endif