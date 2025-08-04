import http from 'k6/http';
import { check, sleep } from 'k6';

// Configuração do teste
export let options = {
  stages: [
    { duration: '15s', target: 20 },
    { duration: '2m', target: 80 },
    { duration: '3m', target: 150 },
    { duration: '2m', target: 200 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    'http_req_duration': ['p(90)<3000'],
    'http_req_failed': ['rate<0.15'],
    'http_reqs': ['rate>10'],
  },
};

// Configuração do Prometheus
const CLUSTER_CONTEXT = __ENV.CLUSTER_CONTEXT || 'aws';
const CURRENT_NAMESPACE = __ENV.NAMESPACE || 'monitoring';
const PROMETHEUS_SVC = 'kube-prometheus-stack-' + CLUSTER_CONTEXT + '-prometheus';
const PROMETHEUS_URL = 'http://' + PROMETHEUS_SVC + ':9090';

// Queries para teste
const queries = [
  'up',
  'prometheus_build_info',
  'prometheus_tsdb_head_series',
  'prometheus_tsdb_head_samples_appended_total',
  'rate(prometheus_tsdb_head_samples_appended_total[5m])',
  'sum(rate(container_cpu_usage_seconds_total[5m])) by (namespace)',
  'count(up == 1)',
  'prometheus_config_last_reload_successful',
  'topk(10, sum(rate(container_cpu_usage_seconds_total[1h])) by (pod))',
  'histogram_quantile(0.95, rate(prometheus_http_request_duration_seconds_bucket[10m]))',
  'sum(increase(prometheus_tsdb_compaction_duration_seconds_sum[2h])) by (job)',
  'avg_over_time(prometheus_tsdb_head_series[30m])',
  'rate(prometheus_rule_evaluation_duration_seconds_sum[15m])',
];

export function setup() {
  console.log('🚀 Iniciando stress test');
  console.log('🌐 Cluster Context: ' + CLUSTER_CONTEXT);
  console.log('📦 Namespace: ' + CURRENT_NAMESPACE);
  console.log('🎯 Target: ' + PROMETHEUS_URL);
  
  // Teste de conectividade
  try {
    let response = http.get(PROMETHEUS_URL + '/api/v1/query?query=up', {
      timeout: '10s'
    });
    
    if (response.status === 200) {
      console.log('✅ Prometheus conectado');
    } else {
      console.log('⚠️ Prometheus status: ' + response.status);
    }
  } catch (error) {
    console.log('❌ Erro na conectividade: ' + error.message);
  }
  
  return {
    startTime: Date.now(),
    testId: __ENV.testid || 'stress-' + Date.now()
  };
}

export default function(data) {
  const vuIteration = __ITER;
  const query = queries[Math.floor(Math.random() * queries.length)];
  
  // Parâmetros da requisição
  const params = {
    headers: {
      'Accept': 'application/json',
      'User-Agent': 'k6-stress-test',
      'X-Test-ID': data.testId,
    },
    timeout: '30s',
    tags: { 
      query_type: getQueryType(query),
      iteration: vuIteration % 100,
    },
  };
  
  // Query instantânea
  const instantUrl = PROMETHEUS_URL + '/api/v1/query?query=' + encodeURIComponent(query);
  let response = http.get(instantUrl, params);
  
  check(response, {
    'query success': function(r) { return r.status === 200; },
    'response time acceptable': function(r) { return r.timings.duration < 10000; },
    'has valid data': function(r) {
      try {
        let data = JSON.parse(r.body);
        return data.status === 'success';
      } catch (e) {
        return false;
      }
    },
  });
  
  // Queries de range ocasionais (mais stress)
  if (vuIteration % 5 === 0) {
    const now = Math.floor(Date.now() / 1000);
    const start = now - 1800; // 30 minutos atrás
    const step = 30; // 30 segundos de step
    
    const rangeUrl = PROMETHEUS_URL + '/api/v1/query_range?query=' + encodeURIComponent(query) + 
                     '&start=' + start + '&end=' + now + '&step=' + step;
    
    let rangeResponse = http.get(rangeUrl, {
      headers: params.headers,
      timeout: '60s',
      tags: { query_type: 'range' }
    });
    
    check(rangeResponse, {
      'range query success': function(r) { return r.status === 200; },
    });
  }
  
  // Queries de metadata ocasionais
  if (vuIteration % 8 === 0) {
    const metadataUrls = [
      PROMETHEUS_URL + '/api/v1/label/job/values',
      PROMETHEUS_URL + '/api/v1/label/instance/values',
      PROMETHEUS_URL + '/api/v1/series?match[]=' + encodeURIComponent(query),
    ];
    
    const metadataUrl = metadataUrls[Math.floor(Math.random() * metadataUrls.length)];
    http.get(metadataUrl, {
      headers: params.headers,
      timeout: '30s',
      tags: { query_type: 'metadata' }
    });
  }
  
  // Log de progresso a cada 50 iterações
  if (vuIteration % 50 === 0 && vuIteration > 0) {
    console.log('📊 VU ' + __VU + ': ' + vuIteration + ' queries executadas');
  }
  
  // Sleep variável
  const sleepTime = Math.random() * 2;
  sleep(sleepTime);
}

function getQueryType(query) {
  if (query.indexOf('rate(') >= 0 || query.indexOf('increase(') >= 0) {
    return 'rate';
  }
  if (query.indexOf('sum(') >= 0 || query.indexOf('avg(') >= 0) {
    return 'aggregation';
  }
  if (query.indexOf('histogram_quantile') >= 0) {
    return 'histogram';
  }
  if (query.indexOf('topk(') >= 0) {
    return 'topk';
  }
  return 'simple';
}

export function teardown(data) {
  const duration = (Date.now() - data.startTime) / 1000;
  
  console.log('');
  console.log('🏁 Stress test finalizado');
  console.log('⏱️ Duração: ' + duration.toFixed(1) + 's');
  console.log('🆔 Test ID: ' + data.testId);
  console.log('🌐 Cluster: ' + CLUSTER_CONTEXT);
  console.log('🎯 Target: ' + PROMETHEUS_URL);
  console.log('');
  console.log('💡 Para verificar impacto, monitore:');
  console.log('   - CPU/Memory dos pods do Prometheus');
  console.log('   - Query duration metrics');
  console.log('   - TSDB head series/samples');
}
