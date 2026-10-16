import MetalKit
import QuartzCore
import SwiftUI

// Shader adapted from Liquid Orb Editor by LerSent001 (MIT).
// Upstream revision: 8d1736e1fc5b41a5037b524403f35b7952b038f0
// https://github.com/LerSent001/orb
// See third-party-licenses/liquid-orb-editor/LICENSE for the retained notice.
// Local adaptations include the Chrome-only shader, press dent and SwiftUI control.
/// The Chrome liquid-orb preset from the supplied native Metal export.
/// Unused shader presets were intentionally omitted so Ask compiles only the
/// artwork it renders.
private let orbMetalSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;
    float time;
    float speed;
    float radius;
    float zoom;
    float warp;
    float ridgeAmt;
    float sharp;
    float shade;
    float sheen;
    float gloss;
    float shellMidAlpha;
    float shellEdgeAlpha;
    float exposure;
    float style;
    float edgeSoftness;
    float edgeGlow;
    float paletteCount;
    float glassEnabled;
    float glassOpacity;
    float contourDeform;
    float pressDepth;
    float _reserved23;
    float4 colorA;
    float4 colorB;
    float4 colorC;
    float4 colorD;
    float4 highlightColor;
    float4 shellInner;
    float4 shellMid;
    float4 shellEdge;
    float4 sheenColor;
    float4 specColor;
    float4 canvasColor;
    float4 glowColor;
    float4 paletteStop0_;
    float4 paletteStop1_;
    float4 paletteStop2_;
    float4 paletteStop3_;
    float4 paletteStop4_;
    float4 paletteStop5_;
    float4 paletteStop6_;
    float4 paletteStop7_;
    float4 paletteStop8_;
    float4 paletteStop9_;
    float4 paletteStop10_;
    float4 paletteStop11_;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

float edgeDelta(float softness) {
    return softness - 0.005;
}

float3 rampColor(float value, constant Uniforms& u) {
    float3 color = mix(u.colorA.xyz, u.colorB.xyz, smoothstep(0.0, 0.45, value));
    color = mix(color, u.colorC.xyz, smoothstep(0.38, 0.72, value));
    return mix(color, u.colorD.xyz, smoothstep(0.68, 1.0, value));
}

float3 finishFluid(float3 color, float2 point, constant Uniforms& u) {
    color = mix(
        color,
        u.highlightColor.xyz,
        (u.shade * 0.22) * smoothstep(0.15, 1.15, dot(point, float2(-0.32, 0.78)))
    );
    color *= 1.0 - ((u.shade * 0.34) * smoothstep(-0.1, 1.2, dot(point, float2(0.45, -0.62))));
    color *= 1.0 - ((u.shade * 0.22) * smoothstep(0.72, 1.08, length(point)));
    return clamp(color, float3(0.0), float3(1.0));
}

float2 rotatePoint(float2 point, float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return float2(
        (cosine * point.x) - (sine * point.y),
        (sine * point.x) + (cosine * point.y)
    );
}

float3 chromeFluid(float2 point, float time, constant Uniforms& u) {
    float2 q = point * (1.0 + (u.zoom * 0.35));
    float amplitude = 0.028 * u.warp;

    for (int index = 1; index <= 9; index++) {
        float layer = float(index);
        q.x += (amplitude / layer) * cos(((layer * 2.7) * q.y) + (time * 0.46));
        q.y += (amplitude / layer) * cos(((layer * 3.1) * q.x) - (time * 0.4));
    }

    float denominator = max(abs(sin(((time * 0.24) - q.y) - q.x)), 0.045);
    float flare = clamp(1.0 / denominator, 0.0, 18.0);
    float metalAmount = smoothstep(1.15, 7.5, flare);
    float fold = 0.5 + (0.5 * cos(((q.x - q.y) * (3.2 + (u.sharp * 0.28))) + (time * 0.32)));
    float value = clamp((metalAmount * 0.74) + (fold * 0.36), 0.0, 1.0);
    float3 color = rampColor(value, u);
    color = mix(color, u.colorA.xyz, pow(metalAmount, 5.0) * 0.62);
    return finishFluid(color, point, u);
}

float3 overColor(float3 destination, float3 source, float alpha) {
    float amount = clamp(alpha, 0.0, 1.0);
    return (source * amount) + (destination * (1.0 - amount));
}

float refractionProfile(float value) {
    float depth = clamp(value, 0.0, 1.0);
    float circular = sqrt(max(1.0 - ((1.0 - depth) * (1.0 - depth)), 0.0));
    return 1.0 - circular;
}

float highlightLobe(float2 normal, float2 direction, float cut, float power) {
    float angular = clamp((dot(normal, direction) - cut) / max(1.0 - cut, 0.001), 0.0, 1.0);
    return pow(angular, power);
}

float3 edgeGlow(
    float3 color,
    float2 uv,
    float radius,
    float softness,
    float glow,
    float3 glowColor
) {
    if (glow <= 0.0) { return color; }
    float distance = length(uv);
    float outside = smoothstep(
        radius - max(softness, 0.0005),
        radius + max(softness, 0.0005),
        distance
    );
    return color + (glowColor * ((glow * exp(-(max(distance - radius, 0.0)) * 11.0)) * outside));
}

float4 renderOrb(float2 uv01, constant Uniforms& u) {
    float2 fragmentPosition = uv01 * u.size;
    float shortestSide = max(min(u.size.x, u.size.y), 1.0);
    float2 uv = ((2.0 * fragmentPosition) - u.size) / shortestSide;
    float pressDepth = clamp(u.pressDepth, 0.0, 1.0);
    uv.y /= 1.0 - (pressDepth * 0.038);
    float radius = max(u.radius, 0.05);
    float animatedTime = u.time * u.speed;

    if (length(uv) > radius * (1.01 + edgeDelta(u.edgeSoftness))) {
        float3 glow = edgeGlow(
            float3(0.0), uv, radius, u.edgeSoftness,
            u.edgeGlow, u.glowColor.xyz
        );
        return float4(clamp(glow, float3(0.0), float3(1.0)), u.edgeGlow > 0.0 ? 1.0 : 0.0);
    }

    float2 point = uv / radius;
    float pointDistance = length(point);
    float dentDistance = length(point - float2(0.0, -0.04));
    float dentCore = exp(-(dentDistance * dentDistance) * 11.0);
    float dentRim = exp(-pow(dentDistance - 0.34, 2.0) * 38.0);
    float clearAlpha = 1.0 - smoothstep(0.995, 1.04, pointDistance);
    float2 normal = pointDistance > 0.0001 ? point / pointDistance : float2(0.0);
    float edgeDepth = max(1.0 - pointDistance, 0.0);
    float refractionWidth = 0.015 + (0.95 * clamp(u.shellMidAlpha, 0.0, 1.0));
    float refractionT = edgeDepth / max(refractionWidth, 0.001);
    float profile = pow(refractionProfile(refractionT), 0.68);
    float refractionAmount = (1.6 * clamp(u.glassOpacity, 0.0, 1.0)) * profile;
    float2 refractedPoint = point - (normal * refractionAmount);
    refractedPoint += point * (dentCore * pressDepth * 0.15);

    float3 fluidColor = float3(0.0);
    if (clearAlpha > 0.0) {
        float channelSplit = ((0.14 * clamp(u.gloss, 0.0, 2.0)) * clamp(u.glassOpacity, 0.0, 1.0)) * profile;
        float3 redSample = chromeFluid(refractedPoint - (normal * channelSplit), animatedTime, u);
        float3 greenSample = chromeFluid(refractedPoint, animatedTime, u);
        float3 blueSample = chromeFluid(refractedPoint + (normal * channelSplit), animatedTime, u);
        fluidColor = float3(redSample.x, greenSample.y, blueSample.z);
    }

    float luminance = dot(fluidColor, float3(0.213, 0.715, 0.072));
    float3 saturated = clamp(
        float3(luminance) + ((fluidColor - float3(luminance)) * 1.22),
        float3(0.0),
        float3(1.0)
    );
    float3 color = overColor(u.canvasColor.xyz, saturated, 0.99 * clearAlpha);
    color *= 1.0 - (pressDepth * dentCore * 0.34);
    color = overColor(color, u.highlightColor.xyz, pressDepth * dentRim * 0.12);

    float surfaceWidth = 0.026 + (0.055 * clamp(u.shellEdgeAlpha, 0.0, 1.0));
    float surfaceBand = (1.0 - smoothstep(0.0, surfaceWidth, edgeDepth)) * clearAlpha;
    float opticalRim = pow(surfaceBand, 1.8);
    color = overColor(color, u.shellInner.xyz, (opticalRim * u.glassOpacity) * 0.45);

    float2 coolDirection = normalize(float2(0.84, 0.54));
    float2 warmDirection = normalize(float2(-0.62, -0.78));
    float coolLobe = highlightLobe(normal, coolDirection, -0.32, 1.8);
    float warmLobe = highlightLobe(normal, warmDirection, -0.28, 2.0);
    float dispersion = (opticalRim * clamp(u.gloss, 0.0, 2.0)) * (0.8 + (0.8 * u.shellEdgeAlpha));
    color = overColor(color, u.shellMid.xyz, dispersion * coolLobe);
    color = overColor(color, u.shellEdge.xyz, dispersion * warmLobe);

    float edgeShadow = (opticalRim * (0.015 + (0.15 * u.shellEdgeAlpha)))
        * (0.15 + (0.85 * max(dot(normal, float2(0.45, -0.89)), 0.0)));
    color *= 1.0 - edgeShadow;

    float2 keyDirection = normalize(float2(-0.68, 0.73));
    float2 fillDirection = normalize(float2(0.74, -0.67));
    float key = ((opticalRim * highlightLobe(normal, keyDirection, 0.2, 2.8)) * clamp(u.sheen, 0.0, 2.0)) * 1.4;
    float fill = ((opticalRim * highlightLobe(normal, fillDirection, 0.4, 3.6)) * clamp(u.sheen, 0.0, 2.0));
    color = overColor(color, u.sheenColor.xyz, key);
    color = overColor(color, u.specColor.xyz, fill);

    float delta = edgeDelta(u.edgeSoftness);
    float orbAlpha = 1.0 - smoothstep(0.99 - delta, 1.01 + delta, pointDistance);
    color = clamp(color * max(u.exposure, 0.0), float3(0.0), float3(1.0)) * orbAlpha;
    color = edgeGlow(color, uv, radius, u.edgeSoftness, u.edgeGlow, u.glowColor.xyz);
    return float4(clamp(color, float3(0.0), float3(1.0)), clamp(orbAlpha, 0.0, 1.0));
}

vertex VertexOut vs_main(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    VertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = (positions[vertexID] + float2(1.0)) * 0.5;
    return output;
}

fragment float4 fs_main(VertexOut input [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float4 orb = renderOrb(input.uv, u);
    float2 fragmentPosition = input.uv * u.size;
    float2 fitPoint = ((2.0 * fragmentPosition) - u.size) / u.size;
    float fitFeather = 2.0 / max(min(u.size.x, u.size.y), 1.0);
    float fitStart = min(mix(u.radius, 1.0, 0.5), 1.0 - fitFeather);
    float fit = 1.0 - smoothstep(fitStart, 1.0, max(abs(fitPoint.x), abs(fitPoint.y)));
    return float4(orb.xyz * fit, orb.a * fit);
}
"""#

// Layout matches the 16-byte aligned Metal Uniforms struct above.
private let orbUniformSeed: [Float] = [
    1, 1, 0, 2, 0.7200000286102295, 0.36000001430511475, 3.799999952316284, 0.4399999976158142,
    5.199999809265137, 0.5799999833106995, 0.36000001430511475, 1.1799999475479126, 0.20000000298023224, 0.2199999988079071, 1.0800000429153442, 12,
    0.004999999888241291, 0, 0, 1, 0.41999998688697815, 0, 0, 0,
    1, 1, 1, 1, 0.7254902124404907, 0.7529411911964417, 0.7921568751335144, 1,
    0.20392157137393951, 0.22745098173618317, 0.26274511218070984, 1, 0.0117647061124444, 0.01568627543747425, 0.019607843831181526, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    0.7254902124404907, 0.7529411911964417, 0.7921568751335144, 1, 1, 1, 1, 1,
    0.9176470637321472, 0.95686274766922, 1, 1, 0.8627451062202454, 0.9176470637321472, 1, 1,
    0.019607843831181526, 0.0235294122248888, 0.0313725508749485, 1, 1, 1, 1, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]

private enum LiquidOrbError: Error {
    case metalUnavailable
    case shaderFunctionMissing(String)
    case commandQueueUnavailable
}

@MainActor
private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let startedAt = CACurrentMediaTime()
    private var uniforms = orbUniformSeed
    private var targetPressDepth: Float = 0
    private var renderedPressDepth: Float = 0

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LiquidOrbError.metalUnavailable
        }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let library = try device.makeLibrary(source: orbMetalSource, options: nil)
        guard let vertex = library.makeFunction(name: "vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("vs_main")
        }
        guard let fragment = library.makeFunction(name: "fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("fs_main")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let queue = device.makeCommandQueue() else {
            throw LiquidOrbError.commandQueueUnavailable
        }
        commandQueue = queue
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func setPressDepth(_ value: Float, immediate: Bool) {
        targetPressDepth = min(max(value, 0), 1)
        if immediate {
            renderedPressDepth = targetPressDepth
            uniforms[22] = renderedPressDepth
        }
    }

    func draw(in view: MTKView) {
        guard
            view.drawableSize.width > 0,
            view.drawableSize.height > 0,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(CACurrentMediaTime() - startedAt)
        let response: Float = targetPressDepth > renderedPressDepth ? 0.24 : 0.14
        renderedPressDepth += (targetPressDepth - renderedPressDepth) * response
        uniforms[22] = renderedPressDepth

        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@MainActor
private final class LiquidOrbCoordinator {
    private var renderer: LiquidOrbRenderer?

    func makeView(isPaused: Bool, pressDepth: Float) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        do {
            let renderer = try LiquidOrbRenderer(view: view)
            self.renderer = renderer
            view.delegate = renderer
            update(view: view, isPaused: isPaused, pressDepth: pressDepth)
            return view
        } catch {
            preconditionFailure("Liquid Orb Metal initialization failed: \(error)")
        }
    }

    func update(view: MTKView, isPaused: Bool, pressDepth: Float) {
        view.enableSetNeedsDisplay = isPaused
        view.isPaused = isPaused
        renderer?.setPressDepth(pressDepth, immediate: isPaused)
        if isPaused { view.setNeedsDisplay() }
    }
}

private struct LiquidOrbSurface: UIViewRepresentable {
    let isPaused: Bool
    let pressDepth: Float

    func makeCoordinator() -> LiquidOrbCoordinator { LiquidOrbCoordinator() }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView(isPaused: isPaused, pressDepth: pressDepth)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(view: view, isPaused: isPaused, pressDepth: pressDepth)
    }
}

struct LiquidOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressDepth: Float = 0

    var body: some View {
        LiquidOrbSurface(isPaused: reduceMotion, pressDepth: pressDepth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct OrbPressedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var orbIsPressed: Bool {
        get { self[OrbPressedEnvironmentKey.self] }
        set { self[OrbPressedEnvironmentKey.self] = newValue }
    }
}

struct AuraOrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.orbIsPressed, configuration.isPressed)
            .contentShape(Circle())
            .hoverEffect(.highlight)
    }
}


struct AskLiquidOrbControl: View {
    let isRecording: Bool
    let isStarting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.orbIsPressed) private var isPressed

    var body: some View {
        ZStack {
            ZStack(alignment: .topTrailing) {
                LiquidOrbView(pressDepth: metalPressDepth)
                    .frame(width: 104, height: 104)
                    .opacity(isStarting ? 0.72 : 1)

                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 11, height: 11)
                        .overlay {
                            Circle().stroke(Color(.systemBackground), lineWidth: 3)
                        }
                        .offset(x: 1, y: -1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 104, height: 104)
        }
        .frame(width: 176, height: 176)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: isRecording)
    }

    private var metalPressDepth: Float {
        if isPressed { return 1 }
        if isRecording { return 0.72 }
        if isStarting { return 0.34 }
        return 0
    }
}
