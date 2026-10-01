import com.lesfurets.jenkins.unit.BasePipelineTest
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import org.junit.jupiter.params.provider.ValueSource

import static org.junit.jupiter.api.Assertions.*

class TagUtilsTest extends BasePipelineTest {

    def tagUtils

    @BeforeEach
    void setUp() {
        super.setUp()
        tagUtils = loadScript('vars/tagUtils.groovy')
    }

    static Map v(String prefix, int major, int minor, int patch, String pre = null) {
        [prefix: prefix, major: major, minor: minor, patch: patch, pre: pre]
    }

    // ---------------------------------------------------------------- parseTag

    static List<Arguments> validTags() {
        [
            Arguments.of('1.2.3',             v('',      1, 2, 3)),
            Arguments.of('10.20.30',          v('',      10, 20, 30)),
            Arguments.of('0.0.0',             v('',      0, 0, 0)),
            Arguments.of('a-1.2.3',           v('a',     1, 2, 3)),
            Arguments.of('a-b-c-1.2.3',       v('a-b-c', 1, 2, 3)),
            Arguments.of('svc2-1.2.3',        v('svc2',  1, 2, 3)),
            Arguments.of('1.2.3-rc.1',        v('',      1, 2, 3, 'rc.1')),
            Arguments.of('1.2.3-beta',        v('',      1, 2, 3, 'beta')),
            Arguments.of('1.2.3-rc-1',        v('',      1, 2, 3, 'rc-1')),
            Arguments.of('a-b-c-1.2.3-rc.1',  v('a-b-c', 1, 2, 3, 'rc.1')),
            // Ambiguous: lazy prefix takes the FIRST x.y.z as the version
            Arguments.of('a-1.2.3-4.5.6',     v('a',     1, 2, 3, '4.5.6')),
        ]
    }

    @ParameterizedTest(name = '{0}')
    @MethodSource('validTags')
    void parsesValidTags(String tag, Map expected) {
        assertEquals(expected, tagUtils.parseTag(tag))
    }

    @ParameterizedTest(name = '"{0}"')
    @ValueSource(strings = ['', 'junk', 'a-b-c', '1.2', '1.2.3.4', 'v1.2.3', '-1.2.3', '1.2.3-', 'a-1.2.x'])
    void returnsNullForInvalidTags(String tag) {
        assertNull(tagUtils.parseTag(tag))
    }

    @Test
    void versionPartsAreIntegers() {
        def r = tagUtils.parseTag('a-1.2.3')
        [r.major, r.minor, r.patch].each { assertTrue(it instanceof Integer) }
    }

    // --------------------------------------------------------------- formatTag

    static List<Arguments> formatCases() {
        [
            Arguments.of(v('',      1, 2, 3),         '1.2.3'),
            Arguments.of(v('a-b-c', 1, 2, 3),         'a-b-c-1.2.3'),
            Arguments.of(v('',      1, 2, 3, 'rc.1'), '1.2.3-rc.1'),
            Arguments.of(v('a-b-c', 1, 2, 3, 'rc.1'), 'a-b-c-1.2.3-rc.1'),
            Arguments.of(v('',      0, 0, 0),         '0.0.0'),
            Arguments.of(v('',      10, 20, 30),      '10.20.30'),
            // Empty string and null are equivalent for prefix and pre
            Arguments.of(v(null,    1, 2, 3),         '1.2.3'),
            Arguments.of(v('a',     1, 2, 3, ''),     'a-1.2.3'),
            // Missing keys behave like null
            Arguments.of([major: 1, minor: 2, patch: 3],              '1.2.3'),
            Arguments.of([prefix: 'a', major: 1, minor: 2, patch: 3], 'a-1.2.3'),
        ]
    }

    @ParameterizedTest(name = '{1}')
    @MethodSource('formatCases')
    void formatsTags(Map version, String expected) {
        assertEquals(expected, tagUtils.formatTag(version))
    }

    @Test
    void formatReturnsStringNotGString() {
        assertTrue(tagUtils.formatTag(v('a', 1, 2, 3, 'rc.1')) instanceof String)
    }

    // -------------------------------------------------------------- round trip

    @ParameterizedTest(name = '{0}')
    @MethodSource('validTags')
    void roundTripsThroughParseAndFormat(String tag, Map ignored) {
        assertEquals(tag, tagUtils.formatTag(tagUtils.parseTag(tag)))
    }
}
